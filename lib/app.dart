import 'package:flutter/material.dart';
import 'ui/home_screen.dart';
import 'voice/voice_controller.dart';

class VoiceDemoApp extends StatefulWidget {
  const VoiceDemoApp({super.key});

  @override
  State<VoiceDemoApp> createState() => _VoiceDemoAppState();
}

class _VoiceDemoAppState extends State<VoiceDemoApp> {
  late final VoiceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VoiceController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: HomeScreen(controller: _controller),
    );
  }
}
