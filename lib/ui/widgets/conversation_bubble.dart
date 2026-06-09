import 'package:flutter/material.dart';

class ConversationBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  const ConversationBubble({
    super.key,
    required this.text,
    required this.isUser,
    required this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final bubbleBorder = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomRight: const Radius.circular(16),
      bottomLeft: const Radius.circular(4),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: bubbleBorder,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${timestamp.hour.toString().padLeft(2, '0')}:'
                    '${timestamp.minute.toString().padLeft(2, '0')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
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

class ConversationBubbleList extends StatelessWidget {
  final List<ConversationBubbleData> messages;
  final bool isProcessing;

  const ConversationBubbleList({
    super.key,
    required this.messages,
    this.isProcessing = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 16, bottom: 80),
      itemCount: messages.length + (isProcessing ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == messages.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('思考中...'),
              ],
            ),
          );
        }
        return ConversationBubble(
          text: messages[index].text,
          isUser: messages[index].isUser,
          timestamp: messages[index].timestamp,
        );
      },
    );
  }
}

class ConversationBubbleData {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ConversationBubbleData({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}
