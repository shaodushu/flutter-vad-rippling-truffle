class AppConfig {
  // LLM (DeepSeek / OpenAI compatible)
  static String llmApiKey = 'sk-a1d32c0003394b00b4e75ae0bb69c22f';
  static String llmBaseUrl = 'https://api.deepseek.com';
  static String llmModel = 'deepseek-v4-flash';
  static String systemPrompt = '你是一个友好的中文语音助手。请用中文简洁自然地回答用户的问题。';

  // LiveKit
  static String livekitUrl = 'ws://localhost:7880';
  static String livekitToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJkZXZrZXkiLCJzdWIiOiJmbHV0dGVyX3VzZXIiLCJleHAiOjE3ODExMDczMTMsInZpZGVvIjp7InJvb21Kb2luIjp0cnVlLCJyb29tIjoidm9pY2UtZGVtbyIsImNhblB1Ymxpc2giOnRydWUsImNhblN1YnNjcmliZSI6dHJ1ZSwiY2FuUHVibGlzaERhdGEiOnRydWV9fQ.8xORCJcWR_YLT7C-O2sb910tHwgIqmeVSSXiPN3ag8U';
}
