import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/desktop_settings_screen.dart';
import 'package:pux/src/services/desktop_shell.dart';

/// Stands in for DesktopShell.swift.
class _FakeShell {
  bool closeQuits = false;
  bool startHidden = false;
  String launchAtLogin = 'disabled';
  PlatformException? loginError;
  final calls = <MethodCall>[];

  Map<String, Object?> get settings => {
    'closeQuits': closeQuits,
    'startHidden': startHidden,
    'launchAtLogin': launchAtLogin,
  };

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final enabled = (call.arguments as Map?)?['enabled'] as bool?;
    switch (call.method) {
      case 'getSettings':
        return settings;
      case 'setCloseQuits':
        closeQuits = enabled!;
        return settings;
      case 'setStartHidden':
        startHidden = enabled!;
        return settings;
      case 'setLaunchAtLogin':
        if (loginError != null) throw loginError!;
        launchAtLogin = enabled! ? 'enabled' : 'disabled';
        return settings;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _FakeShell shell;

  setUp(() {
    shell = _FakeShell();
    messenger.setMockMethodCallHandler(DesktopShell.channel, shell.handle);
  });

  tearDown(
    () => messenger.setMockMethodCallHandler(DesktopShell.channel, null),
  );

  group('DesktopSettings', () {
    test('reads the native map', () {
      final settings = DesktopSettings.fromMap({
        'closeQuits': true,
        'startHidden': false,
        'launchAtLogin': 'requiresApproval',
      });
      expect(settings.closeQuits, isTrue);
      expect(settings.startHidden, isFalse);
      expect(settings.launchAtLogin, LaunchAtLogin.requiresApproval);
    });

    test('treats missing or unknown values as off and unsupported', () {
      final settings = DesktopSettings.fromMap({'launchAtLogin': 'later'});
      expect(settings.closeQuits, isFalse);
      expect(settings.startHidden, isFalse);
      expect(settings.launchAtLogin, LaunchAtLogin.unsupported);
    });
  });

  test('only macOS has the menu bar app', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        DesktopShell.instance.isSupported,
        platform == TargetPlatform.macOS,
        reason: platform.name,
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('showWindow does nothing outside macOS', (tester) async {
    await DesktopShell.instance.showWindow();
    expect(shell.calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('showWindow survives a missing channel', (tester) async {
    messenger.setMockMethodCallHandler(
      DesktopShell.channel,
      (_) async => throw MissingPluginException(),
    );
    await DesktopShell.instance.showWindow();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the menu bar Settings item calls back', (tester) async {
    var opened = 0;
    DesktopShell.instance.listen(onOpenSettings: () => opened++);

    await messenger.handlePlatformMessage(
      DesktopShell.channel.name,
      DesktopShell.channel.codec.encodeMethodCall(
        const MethodCall('openSettings'),
      ),
      (_) {},
    );

    expect(opened, 1);
    DesktopShell.channel.setMethodCallHandler(null);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  group('DesktopSettingsScreen', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: DesktopSettingsScreen()));
      await tester.pumpAndSettle();
    }

    SwitchListTile tile(WidgetTester tester, String title) => tester
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

    testWidgets('defaults keep pux in the menu bar', (tester) async {
      await open(tester);

      expect(tile(tester, 'Open at login').value, isFalse);
      expect(tile(tester, 'Start in the menu bar').value, isFalse);
      expect(tile(tester, 'Quit when the window is closed').value, isFalse);
      expect(find.textContaining('keeps pux in the menu bar'), findsOneWidget);
    });

    testWidgets('each switch saves its setting', (tester) async {
      await open(tester);

      await tester.tap(find.text('Open at login'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start in the menu bar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quit when the window is closed'));
      await tester.pumpAndSettle();

      expect(shell.launchAtLogin, 'enabled');
      expect(shell.startHidden, isTrue);
      expect(shell.closeQuits, isTrue);
      expect(tile(tester, 'Open at login').value, isTrue);
      expect(find.textContaining('codes stop arriving'), findsOneWidget);
    });

    testWidgets('a refused login item is reported and left off', (
      tester,
    ) async {
      shell.loginError = PlatformException(
        code: 'launch_at_login_failed',
        message: 'Operation not permitted',
      );
      await open(tester);

      await tester.tap(find.text('Open at login'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Operation not permitted'), findsOneWidget);
      expect(tile(tester, 'Open at login').value, isFalse);
    });

    testWidgets('a login item awaiting approval links to System Settings', (
      tester,
    ) async {
      shell.launchAtLogin = 'requiresApproval';
      await open(tester);

      expect(tile(tester, 'Open at login').value, isTrue);
      await tester.tap(find.text('Open Login Items'));
      await tester.pump();

      expect(shell.calls.last.method, 'openLoginItemsSettings');
    });

    testWidgets('older macOS disables the login switch', (tester) async {
      shell.launchAtLogin = 'unsupported';
      await open(tester);

      expect(tile(tester, 'Open at login').onChanged, isNull);
      expect(find.text('Needs macOS 13 or later.'), findsOneWidget);
    });

    testWidgets('tracks whether it is open', (tester) async {
      expect(DesktopSettingsScreen.isOpen, isFalse);
      await open(tester);
      expect(DesktopSettingsScreen.isOpen, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(DesktopSettingsScreen.isOpen, isFalse);
    });
  });
}
