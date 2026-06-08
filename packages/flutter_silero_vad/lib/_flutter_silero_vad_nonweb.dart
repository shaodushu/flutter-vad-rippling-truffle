import 'flutter_silero_vad_platform_interface.dart';

// Stub class for non-web platforms.
// On web (dart.library.io unavailable), the real WebFlutterSileroVad is used.
// This stub exists only so the conditional import compiles on Android/iOS.
// It is never instantiated since kIsWeb is false on non-web.
class WebFlutterSileroVad extends FlutterSileroVadPlatform {}
