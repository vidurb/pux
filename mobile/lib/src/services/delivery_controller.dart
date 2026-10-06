import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../firebase_status.dart';
import 'api_client.dart';
import 'delivery_runtime.dart';
import 'delivery_service.dart';
import 'record_store.dart';

enum DeliveryState {
  /// Not enrolled, or not started yet.
  idle,
  connecting,
  ready,

  /// A transient failure; another attempt is scheduled.
  retrying,

  /// Push cannot work in this build; retrying will not help.
  firebaseUnconfigured,

  /// The server does not know this relay any more; the user must reset.
  recordUnknown,
}

@immutable
class DeliveryStatus {
  const DeliveryStatus(this.state, {this.message, this.undecryptable = 0});

  final DeliveryState state;
  final String? message;

  /// Deliveries this session that could not be decrypted with the stored key.
  final int undecryptable;

  DeliveryStatus copyWith({DeliveryState? state, String? message, int? undecryptable}) =>
      DeliveryStatus(
        state ?? this.state,
        message: message,
        undecryptable: undecryptable ?? this.undecryptable,
      );
}

/// Starts delivery (FCM registration or the desktop socket) off the startup
/// path, retries transient failures with backoff, and exposes the outcome to
/// the UI. Nothing here may stop the app from rendering.
class DeliveryController {
  DeliveryController._();

  static final DeliveryController instance = DeliveryController._();

  static const _minBackoff = Duration(seconds: 2);
  static const _maxBackoff = Duration(minutes: 5);

  final ValueNotifier<DeliveryStatus> status = ValueNotifier(
    const DeliveryStatus(DeliveryState.idle),
  );

  DeliveryService get _service => deliveryServiceForPlatform();

  Timer? _retryTimer;
  int _attempt = 0;
  bool _running = false;

  /// Starts (or restarts) delivery. Safe to call repeatedly.
  Future<void> start() async {
    _retryTimer?.cancel();
    _attempt = 0;
    await _tryStart();
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _service.stop();
    status.value = const DeliveryStatus(DeliveryState.idle);
  }

  void reportReady() => _set(DeliveryState.ready);

  /// For failures the service handles itself (e.g. the desktop socket's own
  /// reconnect loop), so the UI still shows them.
  void reportError(Object error) {
    if (error is RecordNotFoundException) {
      _set(DeliveryState.recordUnknown, message: error.toString());
      unawaited(_service.stop());
    } else {
      _set(DeliveryState.retrying, message: error.toString());
    }
  }

  void reportUndecryptable() {
    status.value = status.value.copyWith(
      state: status.value.state,
      message: status.value.message,
      undecryptable: status.value.undecryptable + 1,
    );
  }

  Future<void> _tryStart() async {
    if (_running) return;
    if (!await RecordStore.instance.isEnrolled()) {
      _set(DeliveryState.idle);
      return;
    }

    _running = true;
    _set(DeliveryState.connecting);
    try {
      await _service.init();
      _attempt = 0;
      _set(DeliveryState.ready);
    } on FirebaseNotConfiguredException catch (error) {
      _set(DeliveryState.firebaseUnconfigured, message: error.toString());
    } on RecordNotFoundException catch (error) {
      _set(DeliveryState.recordUnknown, message: error.toString());
    } catch (error, stackTrace) {
      debugPrint('Delivery start failed: $error\n$stackTrace');
      final delay = backoff(_attempt++);
      _set(DeliveryState.retrying, message: '$error (retrying in ${delay.inSeconds}s)');
      _retryTimer = Timer(delay, _tryStart);
    } finally {
      _running = false;
    }
  }

  void _set(DeliveryState state, {String? message}) {
    status.value = status.value.copyWith(state: state, message: message);
  }

  /// Exponential backoff with jitter, from [_minBackoff] up to [_maxBackoff].
  static Duration backoff(int attempt, {Random? random}) {
    final base = _minBackoff.inMilliseconds * pow(2, min(attempt, 16));
    final capped = min(base, _maxBackoff.inMilliseconds).toInt();
    final jitter = (random ?? Random()).nextInt(capped ~/ 4 + 1);
    return Duration(milliseconds: min(capped + jitter, _maxBackoff.inMilliseconds));
  }
}
