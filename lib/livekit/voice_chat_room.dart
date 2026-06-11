import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audio_session/audio_session.dart';
import 'package:fireredvad/fireredvad.dart';
import '../config/app_config.dart';
import 'voice_chat_state.dart';

/// Represents a single message in the conversation.
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}

/// Manages LiveKit room connection, audio publish/subscribe, and Agent
/// data channel communication.
class VoiceChatRoom {
  Room? _room;
  bool _disposed = false;
  bool _connecting = false;
  int _connectGen = 0;  // 递增后取消进行中的旧 connect()
  CancelListenFunc? _cancelListen;

  // --- Reactive state ---
  final state = ValueNotifier<VoiceChatState>(VoiceChatState.disconnected);
  final transcript = ValueNotifier<String>('');
  final response = ValueNotifier<String>('');
  final streamingResponse = ValueNotifier<String>('');  // TTS 逐句输出
  final errorMessage = ValueNotifier<String?>('');
  final messages = <ChatMessage>[];
  final audioLevel = ValueNotifier<double>(0.0);
  final localIsSpeaking = ValueNotifier<bool>(false);

  // --- Local VAD (fireredvad + flutter_sound) ---
  FireRedVad? _vad;
  VadStream? _vadStream;
  Timer? _vadTimeout;
  CancelListenFunc? _vadAudioCancel;  // 取消 LiveKit 音频渲染器

  /// Request and verify microphone permission.
  /// Returns true if granted, false otherwise.
  Future<bool> _requestMicPermission() async {
    final status = await Permission.microphone.request();
    if (status == PermissionStatus.granted) return true;

    // If permanently denied, open app settings
    if (status == PermissionStatus.permanentlyDenied) {
      debugPrint('[LK] mic permanently denied, opening settings');
      await openAppSettings();
    }

    return false;
  }

  /// Connect to LiveKit Server and join a room.
  Future<void> connect() async {
    if (_connecting || state.value == VoiceChatState.connected) return;
    _connecting = true;
    final gen = ++_connectGen;

    // 清理旧连接（可能在 resumeAfterSleep 后残留）
    _vadAudioCancel?.call();
    _vadAudioCancel = null;
    _cancelListen?.call();
    _cancelListen = null;
    await _room?.disconnect();
    _room = null;

    state.value = VoiceChatState.connecting;
    debugPrint('[LK] connecting to ${AppConfig.livekitUrl}');

    // Request mic permission first
    if (!await _requestMicPermission()) {
      errorMessage.value = '需要麦克风权限，请在设置中开启';
      state.value = VoiceChatState.error;
      _connecting = false;
      return;
    }

    try {
      // 配置音频会话：允许与其他 app 混音，不独占麦克风
      // 注意：WebRTC 也会管理音频会话，如果冲突可注释掉这段
      // final session = await AudioSession.instance;
      // await session.configure(AudioSessionConfiguration(
      //   avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      //   avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions
      //       .mixWithOthers |
      //       AVAudioSessionCategoryOptions.defaultToSpeaker,
      //   avAudioSessionMode: AVAudioSessionMode.voiceChat,
      //   androidAudioAttributes: AndroidAudioAttributes(
      //     contentType: AndroidAudioContentType.speech,
      //     usage: AndroidAudioUsage.voiceCommunication,
      //   ),
      //   androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // ));

      _room = Room(
        roomOptions: RoomOptions(
          defaultAudioCaptureOptions: const AudioCaptureOptions(
            echoCancellation: true,
            autoGainControl: true,
            noiseSuppression: false,
            highPassFilter: false,
            voiceIsolation: false,
            typingNoiseDetection: false,
          ),
        ),
      );

      // Listen to events
      _cancelListen = _room!.events.on<RoomEvent>(_onRoomEvent);

      // Connect and enable microphone
      final token = await _getToken();
      if (gen != _connectGen) {
        debugPrint('[LK] connect superseded (gen $gen != $_connectGen)');
        _connecting = false;
        return;
      }

      await _room!.connect(AppConfig.livekitUrl, token);
      if (gen != _connectGen) {
        debugPrint('[LK] connect superseded after _room.connect');
        // _room might have been disconnected by newer connect → 不碰 state
        _connecting = false;
        return;
      }

      await _room!.localParticipant?.setMicrophoneEnabled(true);

      state.value = VoiceChatState.connected;
      _connecting = false;
      debugPrint('[LK] connected');

      // Start local VAD for faster UI response
      _startLocalVad();
    } catch (e) {
      if (gen != _connectGen) {
        // 被较新的 connect() 取代了，不覆盖它的状态
        debugPrint('[LK] connect (gen $gen) error ignored — superseded');
        _connecting = false;
        return;
      }
      debugPrint('[LK] connect error: $e');
      errorMessage.value = '连接失败: $e';
      state.value = VoiceChatState.error;
      _connecting = false;
    }
  }

  void _onRoomEvent(RoomEvent event) {
    switch (event) {
      case DataReceivedEvent e:
        _handleData(e.data);
      case ActiveSpeakersChangedEvent e:
        _onActiveSpeakersChanged(e.speakers);
      case ParticipantConnectedEvent e:
        debugPrint('[LK] participant joined: ${e.participant.identity}');
      case ParticipantDisconnectedEvent e:
        debugPrint('[LK] participant left: ${e.participant.identity}');
      case RoomDisconnectedEvent():
        debugPrint('[LK] disconnected');
        if (!_disposed) state.value = VoiceChatState.disconnected;
      default:
        break;
    }
  }

  void _onActiveSpeakersChanged(List<Participant> speakers) {
    if (speakers.isNotEmpty) {
      // speakers are sorted by audio level, loudest first
      audioLevel.value = speakers.first.audioLevel;
    } else {
      audioLevel.value = 0.0;
    }
  }

  /// Start local VAD using fireredvad fed by LiveKit's local audio track.
  /// Uses addAudioRenderer instead of a separate microphone recorder,
  /// avoiding double-mic contention and freeing the mic for other apps.
  Future<void> _startLocalVad() async {
    if (_disposed) return;
    try {
      // 1. Load fireredvad model
      final weights = await rootBundle.load('assets/vad/weights.bin');
      final cmvnJson = await rootBundle.loadString('assets/vad/cmvn.json');
      _vad = FireRedVad.load(weights, cmvnJson, enableAed: false);
      _vadStream = _vad!.createStream(
        speechThreshold: 0.5,
        minSpeechFrames: 8,       // 80ms 连续语音才触发
        minSilenceFrames: 30,     // 300ms 静音才结束
        maxSpeechFrames: 300,     // 3s 强制结束（防噪音导致永不停止）
      );

      // 2. Get Local Audio Track from LiveKit room (already capturing mic)
      LocalAudioTrack? track;
      for (int retry = 0; retry < 5; retry++) {
        track = _room?.localParticipant
            ?.getTrackPublicationBySource(TrackSource.microphone)
            ?.track as LocalAudioTrack?;
        if (track != null) break;
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (track == null) {
        debugPrint('[VAD] local audio track not available after retries');
        return;
      }

      // 3. Register audio renderer to receive raw PCM frames
      //    Reuses LiveKit's mic capture — no second recorder needed.
      _vadAudioCancel = track.addAudioRenderer(
        options: const AudioRendererOptions(
          sampleRate: 16000,
          channels: 1,
          format: AudioFormat.Int16,
        ),
        onFrame: _onVadAudioFrame,
      );

      debugPrint('[VAD] local VAD started via LiveKit audio renderer');
    } catch (e) {
      debugPrint('[VAD] local VAD init error: $e');
    }
  }

  /// Callback for LiveKit audio renderer — feeds raw PCM into fireredvad.
  void _onVadAudioFrame(AudioFrame frame) {
    if (_disposed || _vadStream == null) return;

    final pcm = Int16List.view(
      frame.data.buffer,
      frame.data.offsetInBytes,
      frame.data.lengthInBytes ~/ 2,
    );

    // Debug: 每 50 帧打印一次音频能量
    final energy = pcm.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
    if (energy > 100) {
      debugPrint('[VAD] audio energy=$energy, len=${pcm.length}');
    }

    final events = _vadStream!.processChunk(pcm);
    for (final event in events) {
      final speaking = event.type == 'speech_start';
      localIsSpeaking.value = speaking;
      if (speaking && state.value == VoiceChatState.connected) {
        debugPrint('[VAD] speech_start detected, energy=$energy');
        state.value = VoiceChatState.listening;
        _vadTimeout?.cancel();
        _vadTimeout = Timer(const Duration(seconds: 2), () {
          if (state.value == VoiceChatState.listening &&
              !localIsSpeaking.value) {
            state.value = VoiceChatState.connected;
          }
        });
      }
    }
  }

  void _handleData(List<int> raw) {
    try {
      final msg = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      debugPrint('[LK] data: $type');

      switch (type) {
        case 'speech_started':
          state.value = VoiceChatState.listening;
        case 'speech_stopped':
          state.value = VoiceChatState.thinking;
        case 'agent_speaking':
          state.value = VoiceChatState.speaking;
          // 清空流式缓存，占位由第一个 agent_response_chunk 创建
          streamingResponse.value = '';
        case 'agent_finished':
          state.value = VoiceChatState.connected;
        case 'user_transcript':
          final text = msg['text'] as String? ?? '';
          if (text.isNotEmpty) {
            transcript.value = text;
            messages.add(ChatMessage(
              text: text,
              isUser: true,
              timestamp: DateTime.now(),
            ));
          }
        case 'agent_response_chunk':
          // 追加文字到流式缓存，同时更新/创建助理消息气泡
          final chunk = msg['text'] as String? ?? '';
          if (chunk.isNotEmpty) {
            streamingResponse.value = streamingResponse.value + chunk;
            if (messages.isEmpty || messages.last.isUser) {
              // 还没有助理消息占位 — 创建一条
              messages.add(ChatMessage(
                text: streamingResponse.value,
                isUser: false,
                timestamp: DateTime.now(),
              ));
            } else {
              // 已有占位 — 更新文字（打字机增长）
              final idx = messages.length - 1;
              messages[idx] = ChatMessage(
                text: streamingResponse.value,
                isUser: false,
                timestamp: messages[idx].timestamp,
              );
            }
          }
        case 'agent_response':
          final text = msg['text'] as String? ?? '';
          if (text.isNotEmpty) {
            response.value = text;
            final accumulated = streamingResponse.value;
            streamingResponse.value = '';
            final finalText = accumulated.isNotEmpty ? accumulated : text;
            // find last assistant msg (may be behind new user msgs from VAD retriggers)
            int? asstIdx;
            for (int i = messages.length - 1; i >= 0; i--) {
              if (!messages[i].isUser) { asstIdx = i; break; }
            }
            if (asstIdx != null) {
              messages[asstIdx] = ChatMessage(
                text: finalText, isUser: false,
                timestamp: messages[asstIdx].timestamp,
              );
            } else {
              messages.add(ChatMessage(
                text: finalText, isUser: false, timestamp: DateTime.now(),
              ));
            }
          }
      }
    } catch (e) {
      debugPrint('[LK] data parse error: $e');
    }
  }

  Future<String> _getToken() async {
    final jwt = JWT({
      'iss': AppConfig.livekitApiKey,
      'sub': 'flutter_user',
      'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      'video': {
        'roomJoin': true,
        'room': 'voice-demo',
        'canPublish': true,
        'canSubscribe': true,
        'canPublishData': true,
      },
    });
    return jwt.sign(SecretKey(AppConfig.livekitApiSecret));
  }

  /// Disconnect from the room.
  Future<void> disconnect() async {
    _disposed = true;
    _vadAudioCancel?.call();
    _cancelListen?.call();
    await _room?.disconnect();
    _room = null;
    state.value = VoiceChatState.disconnected;
    debugPrint('[LK] disconnected');
  }

  /// 亮屏后恢复：息屏时 OS 会挂起音频和网络，WebRTC 连接已死，全量重连。
  void resumeAfterSleep() {
    debugPrint('[VAD] resuming after sleep — full reconnect');
    _disposed = false;
    _connectGen++;         // 取消进行中的旧 connect()
    _connecting = false;   // 允许新 connect 通过 guard
    _vadAudioCancel?.call();
    _vadAudioCancel = null;
    state.value = VoiceChatState.disconnected;
    connect();
  }

  void dispose() {
    _vadTimeout?.cancel();
    _vadAudioCancel?.call();
    disconnect();
    state.dispose();
    transcript.dispose();
    response.dispose();
    streamingResponse.dispose();
    audioLevel.dispose();
    localIsSpeaking.dispose();
    errorMessage.dispose();
  }
}
