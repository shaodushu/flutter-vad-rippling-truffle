import 'package:flutter/material.dart';
import 'livekit/voice_chat_room.dart';
import 'ui/home_screen.dart';

class VoiceDemoApp extends StatefulWidget {
  const VoiceDemoApp({super.key});

  @override
  State<VoiceDemoApp> createState() => _VoiceDemoAppState();
}

class _VoiceDemoAppState extends State<VoiceDemoApp> {
  late final VoiceChatRoom _room;

  @override
  void initState() {
    super.initState();
    _room = VoiceChatRoom();
  }

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '语音对话',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: HomeScreen(room: _room),
    );
  }
}
