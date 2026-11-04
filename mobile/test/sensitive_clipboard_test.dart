import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/sensitive_clipboard.dart';

void main() {
  late String? clipboard;
  late List<MethodCall> nativeCalls;

  setUp(() {
    clipboard = null;
    nativeCalls = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return {'text': clipboard};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(SensitiveClipboard.channel, null);
  });

  void mockNative() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SensitiveClipboard.channel,
      (call) async {
        nativeCalls.add(call);
        return null;
      },
    );
  }

  testWidgets('Android copies through the native sensitive clipboard', (tester) async {
    mockNative();

    await SensitiveClipboard.instance.copy('482913');

    expect(nativeCalls.single.method, 'copySensitive');
    expect(nativeCalls.single.arguments, {'text': '482913', 'clearAfterMs': 60000});
    expect(clipboard, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('falls back to the plain clipboard without the native channel', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SensitiveClipboard.channel,
      (call) async => throw MissingPluginException(),
    );

    await SensitiveClipboard.instance.copy('482913');
    expect(clipboard, '482913');

    await tester.pump(const Duration(seconds: 61));
    expect(clipboard, '');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('clears the clipboard after a minute if it still holds the copy', (tester) async {
    await SensitiveClipboard.instance.copy('482913');
    expect(clipboard, '482913');

    await tester.pump(const Duration(seconds: 59));
    expect(clipboard, '482913');

    await tester.pump(const Duration(seconds: 2));
    expect(clipboard, '');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('leaves the clipboard alone if something else was copied', (tester) async {
    await SensitiveClipboard.instance.copy('482913');
    clipboard = 'something else';

    await tester.pump(const Duration(seconds: 61));
    expect(clipboard, 'something else');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('iOS never reads the clipboard back', (tester) async {
    await SensitiveClipboard.instance.copy('482913');

    await tester.pump(const Duration(seconds: 61));
    expect(clipboard, '482913');
    expect(defaultTargetPlatform, TargetPlatform.iOS);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
