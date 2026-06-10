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

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _waveformAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.room.transcript.addListener(_onDataUpdate);
    widget.room.response.addListener(_onDataUpdate);
    widget.room.streamingResponse.addListener(_onDataUpdate);
    // Continuous waveform animation at ~60fps
    _waveformAnimation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    // Auto-connect to LiveKit
    widget.room.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 亮屏后恢复 VAD 和连接
    if (state == AppLifecycleState.resumed) {
      widget.room.resumeAfterSleep();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waveformAnimation.dispose();
    widget.room.transcript.removeListener(_onDataUpdate);
    widget.room.response.removeListener(_onDataUpdate);
    widget.room.streamingResponse.removeListener(_onDataUpdate);
    super.dispose();
  }

  void _onDataUpdate() {
    setState(() {});
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
          // Conversation bubbles (rebuilds via setState from transcript/response)
          Expanded(
            child: ConversationBubbleList(
              messages: widget.room.messages
                  .map((m) => ConversationBubbleData(
                        text: m.text,
                        isUser: m.isUser,
                        timestamp: m.timestamp,
                      ))
                  .toList(),
              isProcessing: widget.room.state.value == VoiceChatState.thinking,
            ),
          ),

          // Bottom: waveform + status
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            color: theme.colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Animated waveform (60fps via AnimationController)
                  SizedBox(
                    width: 200,
                    child: AnimatedBuilder(
                      animation: _waveformAnimation,
                      builder: (context, _) {
                        final state = widget.room.state.value;
                        return Opacity(
                          opacity: state == VoiceChatState.listening ||
                                  state == VoiceChatState.speaking
                              ? 1.0
                              : 0.3,
                          child: WaveformView(
                            level: widget.room.audioLevel.value,
                            phase: _waveformAnimation.value,
                            color: _statusColor(state),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Status label (only rebuilds on state change)
                  ValueListenableBuilder<VoiceChatState>(
                    valueListenable: widget.room.state,
                    builder: (context, state, _) {
                      return Text(
                        chatStateLabel(state),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: _statusColor(state),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
