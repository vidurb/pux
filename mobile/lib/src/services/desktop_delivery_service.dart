import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'delivery_controller.dart';
import 'delivery_service.dart';
import 'notification_permissions.dart';
import 'notification_service.dart';
import 'record_store.dart';

/// A decrypted code that may not have reached the user, kept for the home
/// screen. Lives in memory only: decrypted codes are never written to disk.
class HeldDelivery {
  HeldDelivery({
    required this.deliveryId,
    required this.notification,
    required this.expiresAt,
    required this.notified,
  });

  final String deliveryId;
  final RelayNotification notification;
  final DateTime expiresAt;

  /// Whether the notification was handed to the OS. Says nothing about whether
  /// the OS showed it.
  bool notified;
}

/// Desktop delivery: a WebSocket for live envelopes, with a poll of pending
/// deliveries on every (re)connect so nothing sent while offline is missed.
///
/// Acknowledging deletes the server's copy, so a delivery is acknowledged only
/// once its notification has gone to an OS that reports notifications on. The
/// state is read afresh for each delivery, because it can change with no event
/// reaching the app, and the first poll runs before the home screen's first
/// check. What that read says decides what happens:
///
/// - `allowed`: show and acknowledge. Linux and Windows always answer this, as
///   they have no permission to read, so the OS can still drop a code there.
/// - `off`: hold, without showing. The code appears in [held] and stays on the
///   server, and is shown and acknowledged when notifications come back.
/// - `quiet`, or the read failed: show and also hold, without acknowledging.
///   The OS may or may not display it. Nothing blocks on the answer: every code
///   is still shown, and the server's expiry bounds what stays unacknowledged.
///   The cost is a repeat notification if the app restarts before expiry, which
///   beats a lost code.
class DesktopDeliveryService implements DeliveryService {
  DesktopDeliveryService._({
    Future<RelayNotification?> Function(Map<String, dynamic> envelope)? decrypt,
    Future<void> Function(RelayNotification notification)? show,
    Future<NotificationAccess?> Function()? checkAccess,
    WebSocketChannel Function(Uri url, Map<String, String> headers)? connect,
    Duration Function(int attempt)? backoff,
    Duration holdFor = _holdFor,
    Duration holdRecheck = _holdRecheck,
  }) : _decrypt = decrypt ?? NotificationService.instance.decrypt,
       _show = show ?? NotificationService.instance.show,
       _checkAccess = checkAccess ?? _readAccess,
       _connect = connect ?? _connectIO,
       _backoff = backoff ?? DeliveryController.backoff,
       _holdDuration = holdFor,
       _holdRecheckInterval = holdRecheck;

  @visibleForTesting
  DesktopDeliveryService.forTesting({
    required Future<RelayNotification?> Function(Map<String, dynamic> envelope) decrypt,
    required Future<void> Function(RelayNotification notification) show,
    required Future<NotificationAccess?> Function() checkAccess,
    required WebSocketChannel Function(Uri url, Map<String, String> headers) connect,
    required Duration Function(int attempt) backoff,
    required Duration holdFor,
    required Duration holdRecheck,
  }) : this._(
         decrypt: decrypt,
         show: show,
         checkAccess: checkAccess,
         connect: connect,
         backoff: backoff,
         holdFor: holdFor,
         holdRecheck: holdRecheck,
       );

  static final DesktopDeliveryService instance = DesktopDeliveryService._();

  /// The longest the server keeps a delivery: its 10 minute limit plus up to 5
  /// until the pruner next runs. The API gives no arrival time, so this counts
  /// from when this app first saw the code, and a poll clears it sooner once the
  /// server has dropped it.
  static const _holdFor = Duration(minutes: 15);

  /// While holding, how often to look for notifications coming back and for
  /// held codes the server has dropped. Coming back has no event unless the user
  /// returns to the app, and nothing runs at all when nothing is held.
  static const _holdRecheck = Duration(seconds: 30);

  static const _pingInterval = Duration(seconds: 30);

  /// The server deletes desktop devices that have not registered for 90 days,
  /// and the socket and polls don't count: they identify the record, not the
  /// device. An app left running for months may never restart or resume, so it
  /// re-registers on this timer. Without a device the server keeps no pending
  /// deliveries for it, and codes would be lost with the socket still open.
  static const _registrationInterval = Duration(hours: 12);

  /// A delivery waits for this, so an OS that never answers mustn't stall it.
  static Future<NotificationAccess?> _readAccess() =>
      NotificationPermissions.instance.check(timeout: const Duration(seconds: 2));

  static WebSocketChannel _connectIO(Uri url, Map<String, String> headers) =>
      IOWebSocketChannel.connect(
        url,
        headers: headers,
        connectTimeout: const Duration(seconds: 15),
      );

  final Future<RelayNotification?> Function(Map<String, dynamic> envelope) _decrypt;
  final Future<void> Function(RelayNotification notification) _show;
  final Future<NotificationAccess?> Function() _checkAccess;
  final WebSocketChannel Function(Uri url, Map<String, String> headers) _connect;
  final Duration Function(int attempt) _backoff;
  final Duration _holdDuration;
  final Duration _holdRecheckInterval;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _registrationTimer;
  bool _stopped = true;
  int _attempt = 0;

  /// Deliveries we failed to decrypt; not acknowledged, so they stay on the
  /// server until it expires them, but not retried or re-reported here.
  final Set<String> _undecryptable = {};

  /// Deliveries being processed, so a poll and the socket can't both take one.
  final Set<String> _inFlight = {};

  /// Deliveries this app is done with. A failed acknowledgement, or a server
  /// that hasn't pruned yet, can list one of these again: it's acknowledged
  /// then, never shown again. Only IDs, so not cleared by [stop].
  final Set<String> _finished = {};

  final Map<String, HeldDelivery> _holding = {};
  Timer? _holdTimer;

  /// Bumped by [stop], so work still running can't put a code back in memory
  /// after the relay has been forgotten.
  int _session = 0;
  bool _flushing = false;
  bool _flushAgain = false;

  /// Codes that may not have reached the user, oldest first.
  final ValueNotifier<List<HeldDelivery>> held = ValueNotifier(const []);

  @override
  Future<void> init() async {
    // Not stop(): a restart can fail while offline, and held codes must stay
    // readable through that.
    await _disconnect();
    _stopped = false;
    _attempt = 0;
    final access = NotificationPermissions.instance.access;
    access.removeListener(_onAccessChanged);
    access.addListener(_onAccessChanged);

    // Registration and the first poll throw to the caller, which retries.
    await _registerDevice();
    keepRegistered();
    await _pollPending();
    unawaited(_connectWebSocket());
  }

  /// Re-registers on a timer until [stop]. A transient failure waits for the
  /// next tick: the server's limit is many ticks away.
  @visibleForTesting
  void keepRegistered({Duration interval = _registrationInterval}) {
    _registrationTimer?.cancel();
    _registrationTimer = Timer.periodic(interval, (_) async {
      try {
        await _registerDevice();
      } on RecordNotFoundException catch (error) {
        DeliveryController.instance.reportError(error);
      } on TooManyDevicesException catch (error) {
        DeliveryController.instance.reportError(error);
      } catch (error) {
        debugPrint('Desktop device refresh failed: $error');
      }
    });
  }

  /// Also clears held codes, since this is how a relay gets forgotten.
  @override
  Future<void> stop() async {
    _session++;
    NotificationPermissions.instance.access.removeListener(_onAccessChanged);
    _holding.clear();
    _publishHeld();
    await _disconnect();
  }

  Future<void> _disconnect() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _registrationTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _reconnectTimer = null;
    _pingTimer = null;
    _registrationTimer = null;
    _subscription = null;
    _channel = null;
  }

  Future<void> _registerDevice() async {
    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    final deviceId = await ApiClient.instance.registerDevice(
      recordId: recordId,
      pushToken: await RecordStore.instance.desktopDeviceId(),
      platform: 'desktop',
    );
    await RecordStore.instance.saveDeviceId(deviceId);
  }

  Future<void> _pollPending() async {
    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    // Only what was held before asking: anything newer may just not be listed.
    final heldBefore = _holding.keys.toSet();
    final pending = await ApiClient.instance.listPendingDeliveries(recordId: recordId);

    // A full page can leave out newer deliveries, so absence proves nothing.
    if (pending.length < ApiClient.pendingPageSize) {
      heldBefore.removeAll(pending.map((delivery) => delivery.deliveryId));
      // Gone from the server: it expired, or another desktop acknowledged it.
      _forgetHeld(heldBefore);
    }

    for (final delivery in pending) {
      await _handleDelivery(
        recordId: recordId,
        deliveryId: delivery.deliveryId,
        envelope: delivery.envelope,
      );
    }
  }

  Future<void> _connectWebSocket() async {
    if (_stopped) return;

    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    try {
      final channel = _connect(Uri.parse(ApiClient.instance.deliveryWebSocketUrl()), {
        'x-pux-token': recordId,
      });
      await channel.ready;
      if (_stopped) {
        await channel.sink.close();
        return;
      }

      _channel = channel;
      _attempt = 0;
      DeliveryController.instance.reportReady();

      _subscription = channel.stream.listen(
        (event) async {
          try {
            await _handleSocketEvent(recordId, event);
          } catch (error, stackTrace) {
            debugPrint('Desktop delivery socket event failed: $error\n$stackTrace');
          }
        },
        onDone: _scheduleReconnect,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('Desktop delivery socket error: $error\n$stackTrace');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(_pingInterval, (_) {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      });

      // The upgrade can complete before the server subscribes this socket to
      // the record's topic; poll once so nothing sent in that gap is missed.
      try {
        await _pollPending();
      } catch (error) {
        debugPrint('Desktop delivery post-connect poll failed: $error');
      }
    } catch (error, stackTrace) {
      debugPrint('Desktop delivery socket connect failed: $error\n$stackTrace');
      _scheduleReconnect(error: error);
    }
  }

  Future<void> _handleSocketEvent(String recordId, dynamic event) async {
    if (event is! String) return;

    final decoded = jsonDecode(event) as Map<String, dynamic>;
    switch (decoded['type']) {
      case 'envelope':
        final deliveryId = decoded['delivery_id'] as String?;
        final envelope = decoded['envelope'] as Map<String, dynamic>?;
        if (deliveryId == null || envelope == null) return;
        await _handleDelivery(recordId: recordId, deliveryId: deliveryId, envelope: envelope);
      case 'pong':
        break;
    }
  }

  Future<void> _handleDelivery({
    required String recordId,
    required String deliveryId,
    required Map<String, dynamic> envelope,
  }) async {
    if (_undecryptable.contains(deliveryId) || _holding.containsKey(deliveryId)) return;
    if (!_inFlight.add(deliveryId)) return;

    final session = _session;
    try {
      if (_finished.contains(deliveryId)) {
        await ApiClient.instance.ackDelivery(recordId: recordId, deliveryId: deliveryId);
        return;
      }

      final notification = await _decrypt(envelope);
      if (session != _session) return;
      if (notification == null) {
        _undecryptable.add(deliveryId);
        DeliveryController.instance.reportUndecryptable();
        return;
      }

      final access = await _checkAccess();
      if (session != _session) return;

      if (access == NotificationAccess.off) {
        _hold(deliveryId, notification, notified: false);
        return;
      }

      final notified = await _tryShow(notification);
      if (session != _session) return;

      if (access == NotificationAccess.allowed && notified) {
        _finished.add(deliveryId);
        await ApiClient.instance.ackDelivery(recordId: recordId, deliveryId: deliveryId);
      } else {
        _hold(deliveryId, notification, notified: notified);
      }
    } finally {
      _inFlight.remove(deliveryId);
    }
  }

  /// A failure here isn't an undecryptable delivery: the code is fine and can
  /// be retried. Logs only the type, since the error could echo the arguments.
  Future<bool> _tryShow(RelayNotification notification) async {
    try {
      await _show(notification);
      return true;
    } catch (error) {
      debugPrint('Showing a notification failed: ${error.runtimeType}');
      return false;
    }
  }

  void _hold(String deliveryId, RelayNotification notification, {required bool notified}) {
    _holding[deliveryId] = HeldDelivery(
      deliveryId: deliveryId,
      notification: notification,
      expiresAt: DateTime.now().add(_holdDuration),
      notified: notified,
    );
    _publishHeld();
  }

  void _forgetHeld(Iterable<String> deliveryIds) {
    if (deliveryIds.isEmpty) return;
    _holding.removeWhere((id, _) => deliveryIds.contains(id));
    _finished.addAll(deliveryIds);
    _publishHeld();
  }

  void _publishHeld() {
    held.value = List.unmodifiable(_holding.values);
    if (_holding.isEmpty) {
      _holdTimer?.cancel();
      _holdTimer = null;
    } else {
      _holdTimer ??= Timer.periodic(_holdRecheckInterval, (_) => unawaited(_recheckHeld()));
    }
  }

  void _onAccessChanged() => unawaited(_flushHeld());

  Future<void> _recheckHeld() async {
    final now = DateTime.now();
    _forgetHeld([
      for (final delivery in _holding.values)
        if (!delivery.expiresAt.isAfter(now)) delivery.deliveryId,
    ]);
    if (_holding.isEmpty) return;

    await _flushHeld();
    if (_holding.isEmpty) return;

    try {
      await _pollPending();
    } on RecordNotFoundException catch (error) {
      DeliveryController.instance.reportError(error);
    } catch (error) {
      debugPrint('Desktop delivery poll while holding failed: $error');
    }
  }

  /// Acts on the current notification state for everything held. Only one runs
  /// at a time. A change arriving during a run triggers one more.
  Future<void> _flushHeld() async {
    if (_flushing) {
      _flushAgain = true;
      return;
    }

    _flushing = true;
    final session = _session;
    try {
      do {
        _flushAgain = false;
        if (_holding.isEmpty) return;

        final access = await _checkAccess();
        if (session != _session) return;

        for (final delivery in _holding.values.toList()) {
          if (access == NotificationAccess.off) {
            // Handed over without an answer, then found to be off: it was
            // probably dropped, so show it again when notifications come back.
            delivery.notified = false;
            continue;
          }

          if (!delivery.notified) {
            delivery.notified = await _tryShow(delivery.notification);
            if (session != _session) return;
          }

          if (access == NotificationAccess.allowed &&
              delivery.notified &&
              _holding.containsKey(delivery.deliveryId)) {
            await _finishHeld(delivery.deliveryId);
            if (session != _session) return;
          }
        }
      } while (_flushAgain);
    } finally {
      _flushing = false;
    }
  }

  /// A failed acknowledgement is retried when a poll lists the delivery again.
  Future<void> _finishHeld(String deliveryId) async {
    _forgetHeld([deliveryId]);
    try {
      final recordId = await RecordStore.instance.recordId();
      if (recordId == null) return;
      await ApiClient.instance.ackDelivery(recordId: recordId, deliveryId: deliveryId);
    } catch (error) {
      debugPrint('Desktop delivery ack failed: $error');
    }
  }

  void _scheduleReconnect({Object? error}) {
    if (_stopped) return;

    _pingTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    if (error != null) DeliveryController.instance.reportError(error);

    final delay = _backoff(_attempt++);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      try {
        await _pollPending();
      } catch (error) {
        if (error is RecordNotFoundException) {
          DeliveryController.instance.reportError(error);
          return;
        }
        debugPrint('Desktop delivery poll failed: $error');
      }
      await _connectWebSocket();
    });
  }
}
