import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/desktop_delivery_service.dart';
import 'package:pux/src/services/notification_permissions.dart';
import 'package:pux/src/services/notification_service.dart';
import 'package:pux/src/services/record_store.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _recordId = '00000000-0000-4000-8000-000000000001';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _never = Duration(hours: 1);

/// The server's pending deliveries. As there, acknowledging removes one, and
/// acknowledging one that's already gone is a 404.
class _FakeServer {
  final pending = <String>[];
  final acks = <String>[];
  int ackFailures = 0;
  int polls = 0;

  http.Response handle(http.Request request) {
    if (request.url.path == '/api/v1/record/devices') {
      return http.Response(jsonEncode({'device_id': 'dev_1'}), 201);
    }
    if (request.method == 'GET') {
      polls++;
      return http.Response(
        jsonEncode({
          'deliveries': [
            for (final id in pending)
              {
                'delivery_id': id,
                'envelope': {'ciphertext': id},
              },
          ],
        }),
        200,
      );
    }
    if (ackFailures > 0) {
      ackFailures--;
      return http.Response('', 503);
    }
    final id = request.url.pathSegments.last;
    if (!pending.remove(id)) return http.Response('', 404);
    acks.add(id);
    return http.Response('', 204);
  }
}

class _FakeSink implements WebSocketSink {
  @override
  void add(dynamic data) {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements WebSocketChannel {
  final controller = StreamController<dynamic>();

  void send(String id) => controller.add(
    jsonEncode({
      'type': 'envelope',
      'delivery_id': id,
      'envelope': {'ciphertext': id},
    }),
  );

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  WebSocketSink get sink => _FakeSink();

  @override
  Future<void> get ready async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeServer server;
  late List<_FakeSocket> sockets;
  late List<String> shown;
  late NotificationAccess? access;
  late bool showFails;
  late Set<String> undecryptable;
  DesktopDeliveryService? current;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
    await RecordStore.instance.saveEnrollment({
      'v': 1,
      'record_id': _recordId,
      'private_key': _key,
      'public_key': _key,
      'inbox': 'token@pux.test',
      'server': 'https://pux.test',
    });

    server = _FakeServer();
    sockets = [];
    shown = [];
    access = NotificationAccess.allowed;
    showFails = false;
    undecryptable = {};
    ApiClient.setInstanceForTesting(
      ApiClient.forTesting(client: MockClient((request) async => server.handle(request))),
    );
    NotificationPermissions.instance.access.value = NotificationAccess.allowed;
  });

  tearDown(() async {
    await current?.stop();
    current = null;
    NotificationPermissions.instance.access.value = NotificationAccess.allowed;
  });

  DesktopDeliveryService service({
    Duration holdFor = _never,
    Duration holdRecheck = _never,
    Future<RelayNotification?> Function(Map<String, dynamic>)? decrypt,
  }) {
    return current = DesktopDeliveryService.forTesting(
      decrypt:
          decrypt ??
          (envelope) async {
            final id = envelope['ciphertext'] as String;
            if (undecryptable.contains(id)) return null;
            return RelayNotification(title: 'OTP', body: 'code-$id', code: 'code-$id');
          },
      show: (notification) async {
        if (showFails) throw StateError('no notification daemon');
        shown.add(notification.body);
      },
      checkAccess: () async => access,
      connect: (_, _) {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      backoff: (_) => const Duration(milliseconds: 1),
      holdFor: holdFor,
      holdRecheck: holdRecheck,
    );
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  /// The real notifier fires only on a change, so these go through off first.
  void notificationsComeBack() {
    final notifier = NotificationPermissions.instance.access;
    access = NotificationAccess.allowed;
    notifier.value = NotificationAccess.off;
    notifier.value = NotificationAccess.allowed;
  }

  List<String> heldIds(DesktopDeliveryService s) =>
      s.held.value.map((delivery) => delivery.deliveryId).toList();

  group('with notifications on', () {
    test('a code is shown and acknowledged', () async {
      server.pending.add('a');
      final s = service();
      await s.init();

      expect(shown, ['code-a']);
      expect(server.acks, ['a']);
      expect(s.held.value, isEmpty);
    });

    test('a delivery on both the socket and a poll is shown once', () async {
      final s = service();
      await s.init();
      await waitFor(() => sockets.isNotEmpty);

      server.pending.add('a');
      sockets.single.send('a');
      await s.init();
      await waitFor(() => sockets.length == 2);
      await settle();

      expect(shown, ['code-a']);
      expect(server.acks, ['a']);
    });

    test('a failed acknowledgement retries without showing the code again', () async {
      server.pending.add('a');
      server.ackFailures = 1;
      final s = service();
      await expectLater(s.init(), throwsA(anything));
      expect(shown, ['code-a']);

      await s.init();

      expect(shown, ['code-a']);
      expect(server.acks, ['a']);
    });
  });

  group('with notifications off', () {
    setUp(() => access = NotificationAccess.off);

    test('a code is not shown or acknowledged, and can be read in the app', () async {
      final before = DeliveryController.instance.status.value.undecryptable;
      server.pending.add('a');
      final s = service();
      await s.init();

      expect(shown, isEmpty);
      expect(server.acks, isEmpty);
      expect(server.pending, ['a']);
      expect(s.held.value.single.notification.body, 'code-a');
      expect(DeliveryController.instance.status.value.undecryptable, before);
    });

    test('the state is read when the code arrives, not taken from the last check', () async {
      // The notifier still says allowed, as it does before the home screen's
      // first check, when the first poll runs.
      expect(NotificationPermissions.instance.access.value, NotificationAccess.allowed);
      server.pending.add('a');
      await service().init();

      expect(server.acks, isEmpty);
    });

    test('turning them back on delivers once, then acknowledges', () async {
      server.pending.addAll(['a', 'b']);
      final s = service();
      await s.init();

      notificationsComeBack();
      await waitFor(() => server.acks.length == 2);
      await settle();

      expect(shown, ['code-a', 'code-b']);
      expect(server.acks, ['a', 'b']);
      expect(s.held.value, isEmpty);
    });

    test('notifications coming back with no event are noticed by the recheck', () async {
      server.pending.add('a');
      final s = service(holdRecheck: const Duration(milliseconds: 2));
      await s.init();
      await settle();
      expect(shown, isEmpty);

      access = NotificationAccess.allowed;
      await waitFor(() => server.acks.length == 1);
      await settle();

      expect(shown, ['code-a']);
    });

    test('a code that expires is cleared and never shown later', () async {
      server.pending.add('a');
      final s = service(
        holdFor: const Duration(milliseconds: 20),
        holdRecheck: const Duration(milliseconds: 2),
      );
      await s.init();
      expect(heldIds(s), ['a']);

      await waitFor(() => s.held.value.isEmpty);

      // The pruner hasn't run yet, so the server can still list it.
      access = NotificationAccess.allowed;
      await s.init();
      await settle();

      expect(shown, isEmpty);
      expect(s.held.value, isEmpty);
    });

    test('a code the server no longer lists is cleared', () async {
      server.pending.add('a');
      final s = service(holdRecheck: const Duration(milliseconds: 2));
      await s.init();
      expect(heldIds(s), ['a']);

      // Pruned, or acknowledged by another desktop.
      server.pending.clear();
      await waitFor(() => s.held.value.isEmpty);

      notificationsComeBack();
      await settle();
      expect(shown, isEmpty);
    });

    test('a full page proves nothing about a held code it leaves out', () async {
      final s = service();
      await s.init();
      await waitFor(() => sockets.isNotEmpty);
      sockets.single.send('new');
      await waitFor(() => s.held.value.length == 1);

      server.pending.addAll([for (var i = 0; i < ApiClient.pendingPageSize; i++) 'old$i']);
      await s.init();

      expect(heldIds(s), contains('new'));
    });

    test('reconnecting neither repeats nor reports a held code', () async {
      final before = DeliveryController.instance.status.value.undecryptable;
      server.pending.add('a');
      final s = service();
      await s.init();
      await waitFor(() => sockets.isNotEmpty);
      await settle();

      final pollsBefore = server.polls;
      await sockets.single.controller.close();
      await waitFor(() => sockets.length == 2);
      await settle();

      // One reconnect's polls, not a loop.
      expect(server.polls, lessThanOrEqualTo(pollsBefore + 2));
      expect(heldIds(s), ['a']);
      expect(shown, isEmpty);
      expect(server.acks, isEmpty);
      expect(DeliveryController.instance.status.value.undecryptable, before);

      notificationsComeBack();
      await waitFor(() => server.acks.length == 1);
      await settle();

      expect(shown, ['code-a']);
      expect(server.acks, ['a']);
    });

    test('a failed restart keeps held codes readable', () async {
      server.pending.add('a');
      final s = service();
      await s.init();

      ApiClient.setInstanceForTesting(
        ApiClient.forTesting(client: MockClient((_) async => http.Response('', 503))),
      );
      await expectLater(s.init(), throwsA(anything));

      expect(heldIds(s), ['a']);
    });

    test('stopping clears held codes and ends the recheck', () async {
      server.pending.add('a');
      final s = service(holdRecheck: const Duration(milliseconds: 2));
      await s.init();
      await s.stop();
      expect(s.held.value, isEmpty);

      final polls = server.polls;
      await settle();
      expect(server.polls, polls);
    });

    test('a code still being decrypted when stopped is not kept', () async {
      final decrypting = Completer<RelayNotification?>();
      server.pending.add('a');
      final s = service(decrypt: (_) => decrypting.future);
      final starting = s.init();
      await waitFor(() => server.polls == 1);

      await s.stop();
      decrypting.complete(const RelayNotification(title: 'OTP', body: 'x', code: 'x'));
      await starting;

      expect(s.held.value, isEmpty);
    });

    test('an undecryptable delivery is still reported once and never held', () async {
      final before = DeliveryController.instance.status.value.undecryptable;
      server.pending.add('bad');
      undecryptable.add('bad');
      final s = service();
      await s.init();
      await s.init();

      expect(DeliveryController.instance.status.value.undecryptable, before + 1);
      expect(s.held.value, isEmpty);
      expect(server.acks, isEmpty);
    });
  });

  for (final (label, state) in [
    ('the check fails', null),
    ('notifications are quiet', NotificationAccess.quiet),
  ]) {
    group('when $label', () {
      setUp(() => access = state);

      test('a code is shown and readable in the app, but not acknowledged', () async {
        server.pending.add('a');
        final s = service();
        await s.init();

        expect(shown, ['code-a']);
        expect(server.acks, isEmpty);
        expect(heldIds(s), ['a']);
      });

      test('it keeps delivering new codes, without repeating them', () async {
        server.pending.add('a');
        final s = service(holdRecheck: const Duration(milliseconds: 2));
        await s.init();
        await waitFor(() => sockets.isNotEmpty);

        sockets.single.send('b');
        await waitFor(() => shown.length == 2);
        await settle();

        expect(shown, ['code-a', 'code-b']);
      });

      test('an answer of "on" acknowledges without showing again', () async {
        server.pending.add('a');
        final s = service();
        await s.init();

        notificationsComeBack();
        await waitFor(() => server.acks.length == 1);
        await settle();

        expect(shown, ['code-a']);
        expect(s.held.value, isEmpty);
      });

      test('an answer of "off" shows it again once they come back', () async {
        server.pending.add('a');
        final s = service(holdRecheck: const Duration(milliseconds: 2));
        await s.init();

        access = NotificationAccess.off;
        await settle();
        expect(server.acks, isEmpty);

        access = NotificationAccess.allowed;
        await waitFor(() => server.acks.length == 1);
        await settle();

        expect(shown, ['code-a', 'code-a']);
      });
    });
  }

  test('a failure showing a code holds it and retries without a tight loop', () async {
    showFails = true;
    final before = DeliveryController.instance.status.value.undecryptable;
    server.pending.add('a');
    final s = service(holdRecheck: const Duration(milliseconds: 10));
    await s.init();

    expect(heldIds(s), ['a']);
    expect(server.acks, isEmpty);
    expect(DeliveryController.instance.status.value.undecryptable, before);

    showFails = false;
    await waitFor(() => server.acks.length == 1);
    await settle();

    expect(shown, ['code-a']);
    expect(s.held.value, isEmpty);
  });
}
