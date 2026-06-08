abstract class AsrService {
  Future<void> start({
    required void Function(String text) onResult,
    void Function()? onListening,
    void Function()? onDone,
    void Function(String error)? onError,
  });

  String? get currentText;
  Future<String> stop();
  bool get isListening;
  void dispose();
}
