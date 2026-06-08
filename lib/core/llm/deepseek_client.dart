import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'llm_client.dart';

class DeepSeekClient implements LLMClient {
  final String baseUrl;
  final String apiKey;
  final String defaultModel;
  http.Client? _httpClient;
  bool _aborted = false;

  DeepSeekClient({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com',
    this.defaultModel = 'deepseek-chat',
  }) : _httpClient = http.Client();

  @override
  Stream<String> streamChat({
    required String systemPrompt,
    required List<ChatMessage> messages,
    String? model,
  }) async* {
    _aborted = false;
    final modelName = model ?? defaultModel;
    debugPrint('[LLM] streamChat model=$modelName messages=${messages.length}');

    final requestMessages = [
      {'role': 'system', 'content': systemPrompt},
      ...messages.map((m) => m.toJson()),
    ];

    final body = jsonEncode({
      'model': modelName,
      'messages': requestMessages,
      'stream': true,
      'temperature': 0.7,
      'max_tokens': 2048,
    });

    try {
      final url = '$baseUrl/chat/completions';
      debugPrint('[LLM] POST $url');
      final request = http.Request('POST', Uri.parse(url))
        ..headers.addAll({
          'Authorization': 'Bearer ${apiKey.length > 8 ? '${apiKey.substring(0, 8)}...' : '(empty)'}',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        })
        ..body = body;

      final response = await _httpClient!.send(request);
      debugPrint('[LLM] response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        debugPrint('[LLM] ERROR: $errorBody');
        yield '[Error: HTTP ${response.statusCode}]';
        return;
      }

      int tokenCount = 0;
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        if (_aborted) break;

        for (final line in chunk.split('\n')) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data == '[DONE]') {
              debugPrint('[LLM] stream DONE, total tokens: $tokenCount');
              continue;
            }
            try {
              final json = jsonDecode(data);
              final content = json['choices']?[0]?['delta']?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                tokenCount++;
                yield content;
              }
            } catch (e) {
              debugPrint('[LLM] parse error: $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[LLM] request failed: $e');
      if (!_aborted) {
        yield '[Error: $e]';
      }
    }
  }

  @override
  void abort() {
    debugPrint('[LLM] abort');
    _aborted = true;
  }

  @override
  void dispose() {
    debugPrint('[LLM] dispose');
    _httpClient?.close();
    _httpClient = null;
  }
}
