import 'package:flutter/material.dart';
import '../livekit/voice_chat_room.dart';
import '../livekit/voice_chat_state.dart';
import 'widgets/conversation_bubble.dart';
import 'widgets/waveform_view.dart';

class HomeScreen extends StatefulWidget {
  final VoiceChatRoom room;

  const HomeScreen({super.key, required this.room});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    widget.room.transcript.addListener(_onTranscript);
    widget.room.response.addListener(_onResponse);
    // Auto-connect to LiveKit
    widget.room.connect();
  }

  @override
  void dispose() {
    widget.room.transcript.removeListener(_onTranscript);
    widget.room.response.removeListener(_onResponse);
    super.dispose();
  }

  void _onTranscript() {
    final text = widget.room.transcript.value;
    if (text.isNotEmpty) {
      setState(() {});
    }
  }

  void _onResponse() {
    final text = widget.room.response.value;
    if (text.isNotEmpty) {
      setState(() {});
    }
  }

  Color _statusColor(VoiceChatState state) {
    return switch (state) {
      VoiceChatState.disconnected => Colors.grey,
      VoiceChatState.connecting => Colors.grey,
      VoiceChatState.connected => Colors.blue,
      VoiceChatState.listening => Colors.red,
      VoiceChatState.thinking => Colors.orange,
      VoiceChatState.speaking => Colors.green,
      VoiceChatState.error => Colors.red,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音对话'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Conversation bubbles
          Expanded(
            child: ValueListenableBuilder<VoiceChatState>(
              valueListenable: widget.room.state,
              builder: (context, state, _) {
                return ConversationBubbleList(
                  messages: widget.room.messages
                      .map((m) => ConversationBubbleData(
                            text: m.text,
                            isUser: m.isUser,
                            timestamp: m.timestamp,
                          ))
                      .toList(),
                  isProcessing: state == VoiceChatState.thinking,
                );
              },
            ),
          ),

          // Bottom: waveform + status
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            color: theme.colorScheme.surface,
            child: SafeArea(
              top: false,
              child: ValueListenableBuilder<VoiceChatState>(
                valueListenable: widget.room.state,
                builder: (context, state, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Waveform
                      SizedBox(
                        width: 200,
                        child: Opacity(
                          opacity: state == VoiceChatState.listening ||
                                  state == VoiceChatState.speaking
                              ? 1.0
                              : 0.3,
                          child: WaveformView(
                            level: state == VoiceChatState.listening ||
                                    state == VoiceChatState.speaking
                                ? 0.3
                                : 0.0,
                            color: _statusColor(state),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Status label
                      Text(
                        chatStateLabel(state),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: _statusColor(state),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
