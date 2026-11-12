import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'api_client.dart';
import 'record_store.dart';

/// The part of Firebase Messaging that registers this app instance with FCM.
abstract class FcmRegistrationSource {
  /// The Firebase Installation ID (FID) FCM registered this app instance with,
  /// after each successful [register] and whenever the FID changes.
  Stream<String> get onRegistered;

  Future<void> register();
}

/// Needs `firebase_messaging_installation_id_enabled` in AndroidManifest.xml
/// and `FirebaseMessagingInstallationIdEnabled` in the iOS Info.plist: without
/// them, the native SDKs refuse [register].
class FirebaseRegistrationSource implements FcmRegistrationSource {
  const FirebaseRegistrationSource();

  @override
  Stream<String> get onRegistered => FirebaseMessaging.instance.onRegistered;

  @override
  Future<void> register() => FirebaseMessaging.instance.register();
}

/// Keeps the server's device row for this phone pointing at its current FID.
///
/// Each registration sends the device ID the server gave last time, so a new
/// FID (or the first FID after an older build's registration token) replaces
/// the old value in that row rather than adding a second device, which would
/// get every code twice.
class FcmRegistration {
  FcmRegistration({
    this._source = const FirebaseRegistrationSource(),
    required this._onRefreshError,
    this.timeout = const Duration(seconds: 30),
  });

  final FcmRegistrationSource _source;
  final void Function(Object error) _onRefreshError;

  /// How long [start] waits for FCM to report the FID after [register].
  final Duration timeout;

  StreamSubscription<String>? _subscription;
  Completer<String>? _awaited;
  Future<void> _queue = Future.value();
  String? _registered;

  /// Registers with FCM, then registers the resulting FID with the server.
  /// Throws what either throws, for the caller to retry; FIDs that arrive
  /// later are registered as they come, and their errors go to the
  /// `onRefreshError` callback.
  Future<void> start() async {
    // onRegistered drops events nobody listens to, so listen before asking.
    _subscription ??= _source.onRegistered.listen(_onRegistered);
    final awaited = _awaited = Completer<String>();
    try {
      await _source.register();
      final fid = await awaited.future.timeout(
        timeout,
        onTimeout: () =>
            throw TimeoutException('FCM did not finish registering', timeout),
      );
      await _enqueue(fid);
    } finally {
      if (identical(_awaited, awaited)) _awaited = null;
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _awaited = null;
  }

  void _onRegistered(String fid) {
    final awaited = _awaited;
    if (awaited != null && !awaited.isCompleted) {
      awaited.complete(fid);
      return;
    }
    // FCM repeats the current FID on routine syncs. The server already has it,
    // and start() refreshes it on every launch anyway.
    if (fid == _registered) return;
    unawaited(_enqueue(fid).catchError(_onRefreshError));
  }

  /// One registration at a time, so each sends the device ID the last returned.
  Future<void> _enqueue(String fid) {
    final run = _queue.then((_) => _send(fid));
    _queue = run.catchError((Object _) {});
    return run;
  }

  Future<void> _send(String fid) async {
    final store = RecordStore.instance;
    final recordId = await store.recordId();
    if (recordId == null) return;

    final deviceId = await ApiClient.instance.registerDevice(
      recordId: recordId,
      pushToken: fid,
      platform: 'fcm',
      replacesDeviceId: await store.deviceId(),
    );
    await store.saveDeviceId(deviceId);
    _registered = fid;
  }
}
