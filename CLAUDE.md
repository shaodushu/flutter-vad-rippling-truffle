# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此仓库中工作时提供指导。

## 常用命令

- `flutter pub get` — 安装依赖（包含本地路径包 `packages/flutter_silero_vad`）
- `flutter run` — 在已连接的设备或模拟器上运行
- `flutter run -d chrome` — 以 Web 应用方式运行（VAD 使用 onnxruntime-web）
- `flutter build apk` — 构建 Android APK
- `flutter build web` — 构建 Web 部署包
- `flutter test` — 运行测试（当前为模板占位测试）
- `flutter analyze` — 运行 Dart 静态分析（使用 `flutter_lints` v6）

## 架构

这是一个**实时语音对话演示**，管线流程为：
**VAD（语音活动检测）→ ASR（语音识别）→ LLM（大语言模型）→ TTS（语音合成）**

### 管线流程（由 `VoiceController` 编排）

```
麦克风 → AudioCapture (PCM16 @ 16kHz) ──→ SileroVadService（512采样点帧处理）
                                           └─ speechEnded 事件 ──→ 停止录音 → PlatformAsr
                                                                              └─ onResult → DeepSeekClient（流式输出）
                                                                                              └─ onDone → FlutterTtsImpl
                                                                                                            └─ onComplete → 恢复监听
```

### 目录结构

- `lib/voice/voice_controller.dart` — 中央编排器；拥有所有服务，驱动管线状态机
- `lib/voice/voice_state.dart` — 状态枚举：`idle → initializing → listening → processing → speaking → error`
- `lib/core/audio/audio_capture.dart` — 封装 `record` 包；将 PCM16 数据块转换为 Float32；为 VAD 累积 512 采样点帧
- `lib/core/vad/silero_vad_service.dart` — 封装 `flutter_silero_vad` 插件；将 ONNX 模型从 assets 复制到本地存储；发出语音开始/结束事件
- `lib/core/asr/platform_asr.dart` — 封装 `speech_to_text` 包；委托给平台内置语音识别
- `lib/core/llm/deepseek_client.dart` — 用于 OpenAI 兼容聊天补全 API 的流式 SSE 客户端
- `lib/core/tts/flutter_tts_impl.dart` — 封装 `flutter_tts` 实现文字转语音播放
- `lib/config/app_config.dart` — 可变静态配置（API 密钥、基础 URL、模型、系统提示词、VAD 参数）；通过设置面板编辑，**不持久化到磁盘**
- `lib/ui/home_screen.dart` — 主界面，包含对话气泡列表、波形视图、文本输入和语音按钮
- `lib/ui/widgets/` — 可复用 UI 组件：`ConversationBubble`、`VoiceButton`、`WaveformView`、`SettingsPanel`
- `packages/flutter_silero_vad/` — 仓库内 Flutter 插件；Android 使用 ONNX Runtime 原生方案，Web 通过 `silero_vad_adapter.js` 使用 `onnxruntime-web`
- `web/silero_vad_adapter.js` — JavaScript 适配器，暴露 `SileroVADAdapter` 类供 Web 端 `dart:js_interop` 使用

### 关键设计说明

- **VoiceController** 使用 `ValueNotifier` 实现响应式状态管理：`state`、`transcript`、`response`、`errorMessage`、`audioLevel`
- **对话历史** 以 `List<ChatMessage>` 形式保存在控制器内存中（不持久化）
- **设置** 存储在静态可变字段（`AppConfig.*`）中；应用重启后重置——不使用任何持久化存储
- **VAD 模型**（`assets/models/silero_vad.onnx`）必须先解压到本地存储才能使用（由 `SileroVadService._copyModelToLocal` 处理）
- **Web VAD** 使用 ONNX Runtime Web（`ort`，从 CDN 加载）；模型字节通过 JS 互操作从 Dart 传入
- **错误处理** 较为简单：错误设置 `errorMessage` 并在 2 秒后重置为 `idle` 状态
- **默认测试**（`test/widget_test.dart`）是 Flutter 模板占位代码，引用了不存在的 `MyApp`——会执行失败，需要更新
