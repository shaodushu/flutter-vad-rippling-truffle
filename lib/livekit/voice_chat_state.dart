/// Chat state driven by Agent data messages.
enum VoiceChatState {
  disconnected,
  connecting,
  connected,
  listening,
  thinking,
  speaking,
  error,
}

/// Returns a Chinese status label for the given [VoiceChatState].
String chatStateLabel(VoiceChatState state) {
  return switch (state) {
    VoiceChatState.disconnected => '未连接',
    VoiceChatState.connecting => '连接中...',
    VoiceChatState.connected => '已连接',
    VoiceChatState.listening => '倾听中...',
    VoiceChatState.thinking => '思考中...',
    VoiceChatState.speaking => '播放中...',
    VoiceChatState.error => '出错了',
  };
}
