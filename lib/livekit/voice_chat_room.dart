import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:fireredvad/fireredvad.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
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
  FlutterSoundRecorder? _vadRecorder;
  StreamController<List<Int16List>>? _vadStreamController;
  StreamSubscription? _vadStreamSubscription;
  Timer? _vadTimeout;

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
    if (state.value == VoiceChatState.connecting ||
        state.value == VoiceChatState.connected) return;

    state.value = VoiceChatState.connecting;
    debugPrint('[LK] connecting to ${AppConfig.livekitUrl}');

    // Request mic permission first
    if (!await _requestMicPermission()) {
      errorMessage.value = '需要麦克风权限，请在设置中开启';
      state.value = VoiceChatState.error;
      return;
    }

    try {
      _room = Room(
        roomOptions: RoomOptions(
          defaultAudioCaptureOptions: const AudioCaptureOptions(
            noiseSuppression: true,
            echoCancellation: true,
            autoGainControl: true,
            highPassFilter: true,        // 滤除低频噪音（路噪、空调等）
            voiceIsolation: true,        // 语音隔离（iOS 16+）
            typingNoiseDetection: true,  // 过滤键盘敲击声
          ),
        ),
      );

      // Listen to events
      _cancelListen = _room!.events.on<RoomEvent>(_onRoomEvent);

      // Connect and enable microphone
      final token = await _getToken();
      await _room!.connect(AppConfig.livekitUrl, token);
      await _room!.localParticipant?.setMicrophoneEnabled(true);

      state.value = VoiceChatState.connected;
      debugPrint('[LK] connected');

      // Start local VAD for faster UI response
      _startLocalVad();
    } catch (e) {
      debugPrint('[LK] connect error: $e');
      errorMessage.value = '连接失败: $e';
      state.value = VoiceChatState.error;
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

  /// Start local VAD using fireredvad + flutter_sound recorder.
  /// Provides faster speech detection than waiting for server round-trip.
  Future<void> _startLocalVad() async {
    if (_disposed) return;
    try {
      // 1. Load fireredvad model
      final weights = await rootBundle.load('assets/vad/weights.bin');
      final cmvnJson = await rootBundle.loadString('assets/vad/cmvn.json');
      _vad = FireRedVad.load(weights, cmvnJson, enableAed: false);
      _vadStream = _vad!.createStream(
        speechThreshold: 0.5,
        minSpeechFrames: 3,
        minSilenceFrames: 10, // ~500ms silence → speech end
      );

      // 2. Open flutter_sound recorder
      _vadRecorder = FlutterSoundRecorder();
      await _vadRecorder!.openRecorder();

      // 3. Start recording to PCM Int16 stream
      _vadStreamController = StreamController<List<Int16List>>();
      _vadStreamSubscription = _vadStreamController!.stream.listen((frames) {
        if (_disposed) return;
        // Mono recording → frames[0] is the PCM data
        final pcm = frames[0];
        final events = _vadStream!.processChunk(pcm);
        for (final event in events) {
          final speaking = event.type == 'speech_start';
          localIsSpeaking.value = speaking;
          if (speaking && state.value == VoiceChatState.connected) {
            // Local VAD detected speech before server → quick transition
            state.value = VoiceChatState.listening;
            _vadTimeout?.cancel();
            _vadTimeout = Timer(const Duration(seconds: 2), () {
              // Safety: if server hasn't confirmed listening within 2s, revert
              if (state.value == VoiceChatState.listening &&
                  !localIsSpeaking.value) {
                state.value = VoiceChatState.connected;
              }
            });
          }
        }
      });

      await _vadRecorder!.startRecorder(
        codec: Codec.pcm16,
        sampleRate: 16000,
        numChannels: 1,
        audioSource: AudioSource.microphone,
        toStreamInt16: _vadStreamController!.sink,
      );

      debugPrint('[VAD] local VAD started');
    } catch (e) {
      debugPrint('[VAD] local VAD init error: $e');
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
    _cancelListen?.call();
    await _room?.disconnect();
    _room = null;
    state.value = VoiceChatState.disconnected;
    debugPrint('[LK] disconnected');
  }

  /// 亮屏后恢复：息屏时 OS 可能挂起音频/网络，亮屏后需要重新拉起 VAD 和连接。
  void resumeAfterSleep() {
    debugPrint('[VAD] resuming after sleep');
    // 1. 如果断开了，尝试重连
    if (state.value == VoiceChatState.disconnected) {
      connect();
      return;
    }
    // 2. 还连着，但本地 VAD 可能已挂起 → 重启 VAD
    _vadStreamSubscription?.cancel();
    _vadStreamController?.close();
    _vadRecorder?.stopRecorder();
    _vadRecorder?.closeRecorder();
    _startLocalVad();
  }

  void dispose() {
    _vadTimeout?.cancel();
    _vadStreamSubscription?.cancel();
    _vadStreamController?.close();
    _vadRecorder?.stopRecorder();
    _vadRecorder?.closeRecorder();
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
