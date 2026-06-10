import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  // LLM (DeepSeek / OpenAI compatible)
  static String get llmApiKey => dotenv.get('DEEPSEEK_API_KEY', fallback: '');
  static String get llmBaseUrl =>
      dotenv.get('DEEPSEEK_BASE_URL', fallback: 'https://api.deepseek.com');
  static String get llmModel =>
      dotenv.get('DEEPSEEK_MODEL', fallback: 'deepseek-v4-flash');
  static String get systemPrompt => dotenv.get(
      'SYSTEM_PROMPT',
      fallback: '你是一个友好的中文语音助手。请用中文简洁自然地回答用户的问题。不要使用任何 Markdown 格式，不要使用表情符号，只输出纯文本。');

  // LiveKit
  static String get livekitUrl =>
      dotenv.get('LIVEKIT_URL', fallback: 'ws://localhost:7880');
  static String get livekitApiKey =>
      dotenv.get('LIVEKIT_API_KEY', fallback: 'devkey');
  static String get livekitApiSecret =>
      dotenv.get('LIVEKIT_API_SECRET', fallback: 'secret');
}
