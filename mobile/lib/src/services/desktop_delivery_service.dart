import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'delivery_service.dart';
import 'notification_service.dart';
import 'record_store.dart';

class DesktopDeliveryService implements DeliveryService {
  DesktopDeliveryService._();

  static final DesktopDeliveryService instance = DesktopDeliveryService._();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _connecting = false;
  bool _stopped = false;

  @override
  Future<void> init() async {
    _stopped = false;
    await _registerDevice();
    await _pollPending();
    await _connectWebSocket();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _subscription = null;
    _channel = null;
  }

  Future<void> _registerDevice() async {
    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    final deviceId = await RecordStore.instance.desktopDeviceId();

    await ApiClient.instance.registerDevice(
      recordId: recordId,
      pushToken: deviceId,
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
    if (_stopped || _connecting) return;

    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    final wsUrl = ApiClient.instance.deliveryWebSocketUrl(recordId);
    _connecting = true;

    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel = channel;
      _subscription = channel.stream.listen(
        (event) async {
          try {
            await _handleSocketEvent(recordId, event);
          } catch (error, stackTrace) {
            debugPrint('Desktop delivery socket event failed: $error\n$stackTrace');
          }
        },
        onDone: _scheduleReconnect,
        onError: (error, stackTrace) {
          debugPrint('Desktop delivery socket error: $error\n$stackTrace');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (error, stackTrace) {
      debugPrint('Desktop delivery socket connect failed: $error\n$stackTrace');
      _scheduleReconnect();
    } finally {
      _connecting = false;
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
        await _handleDelivery(
          recordId: recordId,
          deliveryId: deliveryId,
          envelope: envelope,
        );
      case 'pong':
        break;
    }
  }

  Future<void> _handleDelivery({
    required String recordId,
    required String deliveryId,
    required Map<String, dynamic> envelope,
  }) async {
    await NotificationService.instance.handleEncryptedMessage(envelope);
    await ApiClient.instance.ackDelivery(
      recordId: recordId,
      deliveryId: deliveryId,
    );
  }

  void _scheduleReconnect() {
    if (_stopped) return;

    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () async {
      await _pollPending();
      await _connectWebSocket();
    });
  }
}
