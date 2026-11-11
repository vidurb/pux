// What flutter_local_notifications_linux does when nothing can show a
// notification. It talks to org.freedesktop.Notifications on the session bus,
// through a D-Bus client it builds itself, so these tests swap in a client
// pointed at a bus of their own and drive the plugin's real code.
//
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart'
    hide LinuxFlutterLocalNotificationsPlugin;
// The package exports a stub to the analyzer; this is the class that runs.
import 'package:flutter_local_notifications_linux/src/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_linux/src/dbus_wrapper.dart';
import 'package:flutter_local_notifications_linux/src/notification_info.dart';
import 'package:flutter_local_notifications_linux/src/notifications_manager.dart';
import 'package:flutter_local_notifications_linux/src/platform_info.dart';
import 'package:flutter_local_notifications_linux/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plugin's wrapper, on a given client instead of `DBusClient.session()`.
class _BusAt implements DBusWrapper {
  _BusAt(this.client);

  final DBusClient client;
  late DBusRemoteObject _object;
  late String _destination;

  @override
  void build({required String destination, required String path}) {
    _destination = destination;
    _object = DBusRemoteObject(
      client,
      name: destination,
      path: DBusObjectPath(path),
    );
  }

  @override
  Future<DBusMethodSuccessResponse> callMethod(
    String? interface,
    String name,
    Iterable<DBusValue> values, {
    DBusSignature? replySignature,
    bool noReplyExpected = false,
    bool noAutoStart = false,
    bool allowInteractiveAuthorization = false,
  }) => _object.callMethod(
    interface,
    name,
    values,
    replySignature: replySignature,
    noReplyExpected: noReplyExpected,
    noAutoStart: noAutoStart,
    allowInteractiveAuthorization: allowInteractiveAuthorization,
  );

  @override
  DBusRemoteObjectSignalStream subscribeSignal(String name) =>
      DBusRemoteObjectSignalStream(
        object: _object,
        interface: _destination,
        name: name,
      );
}

/// The real one opens libc.so.6 and reads /proc, so it only runs on Linux.
class _NoPlatformInfo implements LinuxPlatformInfo {
  @override
  Future<LinuxPlatformInfoData> getAll() async => const LinuxPlatformInfoData();
}

class _MemoryStorage implements NotificationStorage {
  @override
  Future<void> forceReloadCache() async {}

  @override
  Future<LinuxNotificationInfo?> getById(int id) async => null;

  @override
  Future<LinuxNotificationInfo?> getBySystemId(int systemId) async => null;

  @override
  Future<bool> insert(LinuxNotificationInfo notification) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A notification server that accepts every notification and shows none, as
/// one in do-not-disturb mode may.
class _DiscardingDaemon extends DBusObject {
  _DiscardingDaemon() : super(DBusObjectPath('/org/freedesktop/Notifications'));

  int received = 0;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name != 'Notify') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    received++;
    return DBusMethodSuccessResponse([DBusUint32(received)]);
  }
}

/// The plugin's settings carry no D-Bus state, so these match the app's.
const _settings = LinuxInitializationSettings(
  defaultActionName: 'Open notification',
);

/// Errors from work the plugin starts but doesn't await, such as subscribing
/// to notification clicks while initialising.
final _unawaitedErrors = <Object>[];

Future<LinuxFlutterLocalNotificationsPlugin> _plugin(DBusClient client) async {
  final plugin = LinuxFlutterLocalNotificationsPlugin.private(
    LinuxNotificationManager.private(
      dbus: _BusAt(client),
      platformInfo: _NoPlatformInfo(),
      storage: _MemoryStorage(),
    ),
  );
  final initialized = Completer<bool?>();
  runZonedGuarded(
    () => plugin.initialize(settings: _settings).then(initialized.complete),
    (error, _) => _unawaitedErrors.add(error),
  );
  expect(
    await initialized.future,
    isTrue,
    reason: 'initialize does not report a missing daemon',
  );
  return plugin;
}

Future<void> _show(LinuxFlutterLocalNotificationsPlugin plugin) => plugin.show(
  id: 1,
  title: 'OTP from HDFC',
  body: '123456',
  notificationDetails: const LinuxNotificationDetails(),
);

/// The server checks no credentials, and the client can only work out a uid on
/// Linux and Windows, so give it one.
DBusClient _clientAt(DBusAddress address) =>
    DBusClient(address, authClient: DBusAuthClient(uid: '1000'));

void main() {
  late Directory dir;

  setUp(() async {
    _unawaitedErrors.clear();
    dir = await Directory.systemTemp.createTemp('pux-dbus-');
  });

  tearDown(() => dir.delete(recursive: true));

  test(
    'with no session bus, the first call fails and every later show hangs',
    () async {
      final plugin = await _plugin(
        _clientAt(DBusAddress.unix(path: '${dir.path}/missing')),
      );
      // Initialising subscribes to clicks, which connects first and fails, out
      // of sight of the caller.
      await pumpEventQueue();
      expect(_unawaitedErrors.single, isA<SocketException>());

      // The client remembers a connection attempt that never completed, so this
      // never finishes: no error to catch and nothing shown.
      await expectLater(
        _show(plugin).timeout(const Duration(milliseconds: 500)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  group('with a session bus', () {
    late DBusServer bus;
    late DBusAddress address;
    final clients = <DBusClient>[];

    setUp(() async {
      bus = DBusServer();
      address = await bus.listenAddress(
        DBusAddress.unix(path: '${dir.path}/bus'),
      );
    });

    tearDown(() async {
      for (final client in clients) {
        await client.close();
      }
      clients.clear();
      await bus.close();
    });

    DBusClient connect() {
      final client = _clientAt(address);
      clients.add(client);
      return client;
    }

    test('and no notification daemon, show throws', () async {
      final plugin = await _plugin(connect());

      // dbus-daemon answers the same once it finds no .service file to start.
      await expectLater(
        _show(plugin),
        throwsA(isA<DBusServiceUnknownException>()),
      );
      expect(_unawaitedErrors, isEmpty);
    });

    test('and a daemon that discards notifications, show succeeds', () async {
      final daemon = _DiscardingDaemon();
      final daemonClient = connect();
      await daemonClient.registerObject(daemon);
      await daemonClient.requestName('org.freedesktop.Notifications');

      final plugin = await _plugin(connect());
      await _show(plugin);

      // Nothing tells the app the notification wasn't displayed.
      expect(daemon.received, 1);
      expect(_unawaitedErrors, isEmpty);
    });
  });
}
