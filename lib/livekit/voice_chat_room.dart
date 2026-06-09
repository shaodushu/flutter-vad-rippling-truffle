import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
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
  final errorMessage = ValueNotifier<String?>('');
  final messages = <ChatMessage>[];

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
    if (state.value == VoiceChatState.connecting) return;

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
        case 'agent_response':
          final text = msg['text'] as String? ?? '';
          if (text.isNotEmpty) {
            response.value = text;
            messages.add(ChatMessage(
              text: text,
              isUser: false,
              timestamp: DateTime.now(),
            ));
          }
      }
    } catch (e) {
      debugPrint('[LK] data parse error: $e');
    }
  }

  Future<String> _getToken() async {
    if (AppConfig.livekitToken.isNotEmpty) return AppConfig.livekitToken;
    return '';
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

  void dispose() {
    disconnect();
    state.dispose();
    transcript.dispose();
    response.dispose();
    errorMessage.dispose();
  }
}
