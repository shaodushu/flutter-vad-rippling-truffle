import 'package:flutter/material.dart';
import '../../config/app_config.dart';

class SettingsPanel extends StatefulWidget {
  final VoidCallback? onSaved;

  const SettingsPanel({super.key, this.onSaved});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _baseUrlCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _systemPromptCtrl;

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController(text: AppConfig.llmApiKey);
    _baseUrlCtrl = TextEditingController(text: AppConfig.llmBaseUrl);
    _modelCtrl = TextEditingController(text: AppConfig.llmModel);
    _systemPromptCtrl = TextEditingController(text: AppConfig.systemPrompt);
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _systemPromptCtrl.dispose();
    super.dispose();
  }

  void _save() {
    AppConfig.llmApiKey = _apiKeyCtrl.text;
    AppConfig.llmBaseUrl = _baseUrlCtrl.text;
    AppConfig.llmModel = _modelCtrl.text;
    AppConfig.systemPrompt = _systemPromptCtrl.text;
    widget.onSaved?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _apiKeyCtrl,
            decoration: const InputDecoration(
              labelText: 'API Key',
              border: OutlineInputBorder(),
              hintText: 'sk-...',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'API Base URL',
              border: OutlineInputBorder(),
              hintText: 'https://api.deepseek.com',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
              hintText: 'deepseek-chat',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _systemPromptCtrl,
            decoration: const InputDecoration(
              labelText: 'System Prompt',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
