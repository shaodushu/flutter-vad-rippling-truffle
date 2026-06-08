abstract class TtsService {
  Future<void> speak(String text);
  Future<void> stop();
  bool get isSpeaking;
  void setSpeed(double speed);
  void setVolume(double volume);
  void setOnComplete(void Function() callback);
  void dispose();
}
