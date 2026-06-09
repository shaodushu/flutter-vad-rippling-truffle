class AppConfig {
  // LLM (DeepSeek / OpenAI compatible)
  static String llmApiKey = '';
  static String llmBaseUrl = 'https://api.deepseek.com';
  static String llmModel = 'deepseek-v4-flash';
  static String systemPrompt = '你是一个友好的中文语音助手。请用中文简洁自然地回答用户的问题。';

  // LiveKit
  static String livekitUrl = 'ws://localhost:7880';
  static String livekitToken =
      '';
}
