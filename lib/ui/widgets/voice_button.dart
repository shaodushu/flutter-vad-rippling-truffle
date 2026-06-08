import 'package:flutter/material.dart';
import '../../voice/voice_state.dart';

class VoiceButton extends StatelessWidget {
  final VoiceState state;
  final VoidCallback? onPressed;

  const VoiceButton({
    super.key,
    required this.state,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String label) = switch (state) {
      VoiceState.idle => (Colors.blue, Icons.mic, 'Tap to Speak'),
      VoiceState.initializing =>
        (Colors.grey, Icons.hourglass_top, 'Initializing...'),
      VoiceState.listening => (Colors.red, Icons.mic, 'Listening...'),
      VoiceState.processing =>
        (Colors.orange, Icons.hourglass_bottom, 'Processing...'),
      VoiceState.speaking => (Colors.green, Icons.volume_up, 'Speaking...'),
      VoiceState.error => (Colors.red, Icons.error_outline, 'Error'),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          height: 72,
          child: FloatingActionButton.large(
            onPressed: state == VoiceState.idle || state == VoiceState.listening
                ? onPressed
                : null,
            backgroundColor: color.withValues(alpha: 0.9),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(icon, key: ValueKey(icon), size: 32, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
        ),
      ],
    );
  }
}
