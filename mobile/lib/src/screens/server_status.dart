import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/delivery_controller.dart';
import '../services/record_store.dart';

enum ServerReachability { checking, reachable, unreachable, serverError }

/// A compact row naming the server this app uses and whether it answers
/// `GET /health`. It checks when shown, when the app resumes and on a tap.
///
/// It covers reachability only; the delivery banner below it says whether this
/// device is registered. The two meet in two places: when delivery starts
/// retrying, the row checks again, so both say the same thing about the server,
/// and when a check the user asked for (a tap or a resume) finds the server
/// reachable while delivery is waiting to retry, delivery retries now instead of
/// waiting out its backoff.
class ServerStatus extends StatefulWidget {
  const ServerStatus({super.key});

  /// The host, and the port if it isn't the scheme's default.
  static String hostOf(String serverUrl) {
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.host.isEmpty) return serverUrl;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  @override
  State<ServerStatus> createState() => _ServerStatusState();
}

class _ServerStatusState extends State<ServerStatus> {
  late final AppLifecycleListener _lifecycle;
  ServerReachability _state = ServerReachability.checking;
  String? _reason;
  int _latestCheck = 0;
  DeliveryState _deliveryState = DeliveryController.instance.status.value.state;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_check(userAsked: true)),
    );
    DeliveryController.instance.status.addListener(_onDeliveryStatus);
    unawaited(_check());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    DeliveryController.instance.status.removeListener(_onDeliveryStatus);
    super.dispose();
  }

  void _onDeliveryStatus() {
    final state = DeliveryController.instance.status.value.state;
    final previous = _deliveryState;
    _deliveryState = state;
    if (state == DeliveryState.retrying && previous != DeliveryState.retrying) {
      unawaited(_check());
    }
  }

  Future<void> _check({bool userAsked = false}) async {
    final check = ++_latestCheck;
    if (_state != ServerReachability.checking) {
      setState(() {
        _state = ServerReachability.checking;
        _reason = null;
      });
    }

    final health = await ApiClient.instance.checkHealth();
    if (!mounted || check != _latestCheck) return;

    setState(() {
      _state = switch (health.state) {
        ServerHealthState.reachable => ServerReachability.reachable,
        ServerHealthState.unreachable => ServerReachability.unreachable,
        ServerHealthState.serverError => ServerReachability.serverError,
      };
      _reason = health.reason;
    });

    if (userAsked &&
        health.state == ServerHealthState.reachable &&
        DeliveryController.instance.status.value.state ==
            DeliveryState.retrying) {
      unawaited(DeliveryController.instance.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ServerStatus.hostOf(RecordStore.instance.serverUrl);
    final reason = _reason == null ? '' : ': $_reason';
    final (Widget icon, String text, Color? color) = switch (_state) {
      ServerReachability.checking => (
        const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        'Checking…',
        null,
      ),
      ServerReachability.reachable => (
        const Icon(Icons.cloud_done_outlined, color: Colors.green),
        'Reachable',
        null,
      ),
      ServerReachability.unreachable => (
        const Icon(Icons.cloud_off_outlined, color: Colors.orange),
        "Can't reach the server$reason",
        Colors.orange,
      ),
      ServerReachability.serverError => (
        const Icon(Icons.error_outline, color: Colors.red),
        'Server error$reason',
        Colors.red,
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: icon,
          title: Text('Server: $host'),
          subtitle: Text(text, style: TextStyle(color: color)),
          trailing: IconButton(
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh),
            onPressed: _state == ServerReachability.checking
                ? null
                : () => unawaited(_check(userAsked: true)),
          ),
          onTap: _state == ServerReachability.checking
              ? null
              : () => unawaited(_check(userAsked: true)),
        ),
      ),
    );
  }
}
