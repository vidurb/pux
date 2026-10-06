import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'delivery_controller.dart';
import 'delivery_service.dart';
import 'notification_service.dart';
import 'record_store.dart';

/// Desktop delivery: a WebSocket for live envelopes, with a poll of pending
/// deliveries on every (re)connect so nothing sent while offline is missed.
class DesktopDeliveryService implements DeliveryService {
  DesktopDeliveryService._();

  static final DesktopDeliveryService instance = DesktopDeliveryService._();

  static const _pingInterval = Duration(seconds: 30);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _stopped = true;
  int _attempt = 0;

  /// Deliveries we failed to decrypt; not acknowledged, so they stay on the
  /// server until it expires them, but not retried or re-reported here.
  final Set<String> _undecryptable = {};

  @override
  Future<void> init() async {
    await stop();
    _stopped = false;
    _attempt = 0;

    // Registration and the first poll throw to the caller, which retries.
    await _registerDevice();
    await _pollPending();
    unawaited(_connectWebSocket());
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _reconnectTimer = null;
    _pingTimer = null;
    _subscription = null;
    _channel = null;
  }

  Future<void> _registerDevice() async {
    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    await ApiClient.instance.registerDevice(
      recordId: recordId,
      pushToken: await RecordStore.instance.desktopDeviceId(),
      platform: 'desktop',
    );
  }

  Future<void> _pollPending() async {
    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    final pending = await ApiClient.instance.listPendingDeliveries(recordId: recordId);
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
      final channel = IOWebSocketChannel.connect(
        Uri.parse(ApiClient.instance.deliveryWebSocketUrl(recordId)),
        headers: {'x-pux-token': recordId},
        connectTimeout: const Duration(seconds: 15),
      );
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
    if (_undecryptable.contains(deliveryId)) return;

    final shown = await NotificationService.instance.handleEncryptedMessage(envelope);
    if (!shown) {
      _undecryptable.add(deliveryId);
      DeliveryController.instance.reportUndecryptable();
      return;
    }

    await ApiClient.instance.ackDelivery(recordId: recordId, deliveryId: deliveryId);
  }

  void _scheduleReconnect({Object? error}) {
    if (_stopped) return;

    _pingTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    if (error != null) DeliveryController.instance.reportError(error);

    final delay = DeliveryController.backoff(_attempt++);
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
