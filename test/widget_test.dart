import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_voice_demo/app.dart';

void main() {
  testWidgets('App launches with waveform and status', (WidgetTester tester) async {
    await tester.pumpWidget(const VoiceDemoApp());

    // Verify the app title appears (Chinese)
    expect(find.text('语音对话'), findsOneWidget);

    // Verify status label appears
    expect(find.textContaining('初始化'), findsOneWidget);
  });
}
