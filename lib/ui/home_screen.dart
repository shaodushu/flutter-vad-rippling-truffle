import 'package:flutter/material.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_state.dart';
import 'widgets/conversation_bubble.dart';
import 'widgets/voice_button.dart';
import 'widgets/waveform_view.dart';
import 'widgets/settings_panel.dart';

class HomeScreen extends StatefulWidget {
  final VoiceController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<ConversationBubbleData> _messages = [];
  final TextEditingController _textCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.transcript.addListener(_onTranscriptChanged);
    widget.controller.response.addListener(_onResponseChanged);
  }

  @override
  void dispose() {
    widget.controller.transcript.removeListener(_onTranscriptChanged);
    widget.controller.response.removeListener(_onResponseChanged);
    _textCtrl.dispose();
    super.dispose();
  }

  void _onTranscriptChanged() {
    final text = widget.controller.transcript.value;
    if (text.isNotEmpty) {
      setState(() {
        _messages.add(ConversationBubbleData(
          text: text,
          isUser: true,
          timestamp: DateTime.now(),
        ));
      });
    }
  }

  void _onResponseChanged() {
    final text = widget.controller.response.value;
    if (text.isNotEmpty) {
      setState(() {
        // Remove last AI message if exists and update
        if (_messages.isNotEmpty && !_messages.last.isUser) {
          _messages.removeLast();
        }
        _messages.add(ConversationBubbleData(
          text: text,
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
    }
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SettingsPanel(
        onSaved: () {
          // Recreate LLM client with new config
          widget.controller.dispose();
        },
      ),
    );
  }

  void _sendText() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    widget.controller.sendText(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Demo'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Conversation bubbles
          Expanded(
            child: ValueListenableBuilder<VoiceState>(
              valueListenable: widget.controller.state,
              builder: (context, state, _) {
                return ConversationBubbleList(
                  messages: _messages,
                  isProcessing: state == VoiceState.processing,
                );
              },
            ),
          ),

          // Status indicator
          ValueListenableBuilder<VoiceState>(
            valueListenable: widget.controller.state,
            builder: (context, state, _) {
              if (state == VoiceState.speaking) {
                return const LinearProgressIndicator();
              }
              return const SizedBox.shrink();
            },
          ),

          // Waveform + Voice Button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: widget.controller.audioLevel,
                    builder: (context, level, _) {
                      return WaveformView(
                        level: level,
                        color: Theme.of(context).colorScheme.primary,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      // Text input
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _textCtrl,
                            decoration: const InputDecoration(
                              hintText: 'Type a message...',
                              border: OutlineInputBorder(),
                              contentPadding:
                                  EdgeInsets.symmetric(horizontal: 12),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _sendText(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _sendText,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Voice button
                  ValueListenableBuilder<VoiceState>(
                    valueListenable: widget.controller.state,
                    builder: (context, state, _) {
                      return VoiceButton(
                        state: state,
                        onPressed: () {
                          if (state == VoiceState.idle) {
                            widget.controller.start();
                          } else {
                            widget.controller.stop();
                          }
                        },
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
