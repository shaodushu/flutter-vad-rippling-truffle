# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 常用命令

- `flutter pub get` — 安装依赖
- `flutter run` — 在已连接的设备或模拟器上运行
- `flutter run -d chrome` — 以 Web 应用方式运行
- `flutter build apk` — 构建 Android APK
- `flutter build web` — 构建 Web 部署包
- `flutter analyze` — 运行 Dart 静态分析（使用 `flutter_lints` v6）
- `flutter test` — 运行测试（注意：`voice_fsm_test.dart`、`vad_smoother_test.dart`、`vad_echo_suppressor_test.dart` 引用了已删除的旧代码，会执行失败；仅 `widget_test.dart` 可用）
- `flutter test test/widget_test.dart` — 运行单个测试文件

### LiveKit 服务

```bash
cd livekit-server
docker compose up -d
```

## 架构

这是一个基于 **LiveKit WebRTC SFU** 的实时语音对话应用。手机端通过 LiveKit 连接到一个 AI Agent 服务（在服务器上运行完整的 VAD→ASR→LLM→TTS 管线），通过 **Data Channel** 接收 Agent 的状态和文本消息。

### 管线流程

```
麦克风 → LiveKit WebRTC Audio Track → 服务器 Agent（VAD→ASR→LLM→TTS）
                                          ↓
                                   Data Channel 消息
                                    （状态 + 文本）
                                          ↓
                                   客户端 UI 渲染
```

客户端仅负责：
1. 通过 WebRTC 将麦克风音频上传到 LiveKit 服务器
2. 通过 Data Channel 接收 Agent 事件（`speech_started`、`speech_stopped`、`user_transcript`、`agent_response` 等）
3. 渲染对话气泡和状态指示器

### 目录结构

- `lib/main.dart` — 入口，加载 `.env` 后启动 `VoiceDemoApp`
- `lib/app.dart` — 根 Widget，创建 `VoiceChatRoom` 实例并传递到 `HomeScreen`
- `lib/livekit/voice_chat_room.dart` — 核心类：管理 LiveKit Room 连接、麦克风权限、音频发布订阅、Data Channel 消息处理，驱动状态机 `VoiceChatState`
- `lib/livekit/voice_chat_state.dart` — 状态枚举：`disconnected → connecting → connected → listening → thinking → speaking → error`
- `lib/config/app_config.dart` — 从 `.env` 读取静态配置（API 密钥、DeepSeek 基础 URL、模型、LiveKit URL/Token）
- `lib/ui/home_screen.dart` — 主界面，自动连接 LiveKit，显示对话气泡列表、波形视图和状态标签
- `lib/ui/widgets/conversation_bubble.dart` — 对话气泡组件，含 `ConversationBubbleList`（列表容器 + 思考中指示器）
- `lib/ui/widgets/waveform_view.dart` — 波形动画组件，`CustomPaint` 实现
- `lib/ui/widgets/settings_panel.dart` — 设置面板（编辑 API Key / Base URL / Model / System Prompt，修改 `AppConfig` 内存字段，**不写入 `.env`**）
- `livekit-server/` — Docker Compose 配置（`livekit/livekit-server:latest`），端口 7880（WebRTC HTTP）/ 7881（TCP）/ 3478（TURN UDP）/ 50000-60000（媒体）
- `web/` — Web 平台入口（`index.html` 加载 `onnxruntime-web` + `silero_vad_adapter.js`，保留 VAD 适配以备 Web 端可能的使用场景）

### 遗留代码说明

- `packages/flutter_silero_vad/` — 仓库内的 Flutter 插件，支持 Android（ONNX Runtime 原生）和 Web（onnxruntime-web），目前**未被主应用使用**
- 测试文件 `test/voice_fsm_test.dart`、`test/vad_smoother_test.dart`、`test/vad_echo_suppressor_test.dart` 引用了已从 `lib/` 删除的旧版代码，会编译失败，需要修复或删除

### 关键设计说明

- **配置管理**：`AppConfig` 从 `.env` 读取静态 getter，`SettingsPanel` 修改的是内存中的可变副本，重启后重置
- **状态管理**：`VoiceChatRoom` 使用 `ValueNotifier` 实现响应式状态：`state`、`transcript`、`response`、`errorMessage`
- **对话历史**：以 `List<ChatMessage>` 形式保存在 `VoiceChatRoom` 内存中，不持久化
- **错误处理**：`VoiceChatRoom` 在连接失败时设置 `errorMessage` 并进入 `error` 状态；`HomeScreen` 自动连接（`initState` 调用 `room.connect()`），无重试逻辑
- **权限**：使用 `permission_handler` 请求麦克风权限；永久拒绝时打开系统设置
