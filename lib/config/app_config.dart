class AppConfig {
  // LLM (DeepSeek / OpenAI compatible)
  static String llmApiKey = '';
  static String llmBaseUrl = 'https://api.deepseek.com';
  static String llmModel = 'deepseek-chat';

  // System prompt for the AI
  static String systemPrompt = 'You are a helpful voice assistant. Keep your responses concise.';

  // Silero VAD
  static double vadThreshold = 0.5;
  static int vadMinSilenceDurationMs = 500; // 500ms silence triggers speech end
  static int vadSpeechPadMs = 30;
}
