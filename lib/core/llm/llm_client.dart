class ChatMessage {
  final String role;
  final String content;

  const ChatMessage({required this.role, required this.content});

  Map<String, String> toJson() => {'role': role, 'content': content};
}

abstract class LLMClient {
  Stream<String> streamChat({
    required String systemPrompt,
    required List<ChatMessage> messages,
    String? model,
  });

  void abort();
  void dispose();
}
