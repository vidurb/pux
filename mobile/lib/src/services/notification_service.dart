import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

import 'crypto_service.dart';
import 'desktop_shell.dart';
import 'sensitive_clipboard.dart';

const _copyActionId = 'copy_code';

/// What a decrypted payload asks us to show. The server sends
/// `{"type": "otp", "otp", "sender", "verified"}` or
/// `{"type": "forward_confirm", "code", "url", "sender", "forwarding_from"}`
/// (code, url and forwarding_from may be null); payloads without a
/// `type` predate the field and are OTPs. `verified: false` means the
/// sender could not be authenticated (no aligned DKIM signature); payloads
/// without the key come from older servers and carry no marker.
@immutable
class RelayNotification {
  const RelayNotification({
    required this.title,
    required this.body,
    this.code,
    this.url,
  });

  factory RelayNotification.fromPayload(Map<String, dynamic> payload) {
    final sender = payload['sender'] as String? ?? 'Unknown sender';

    switch (payload['type'] as String? ?? 'otp') {
      case 'forward_confirm':
        final code = payload['code'] as String?;
        final url = payload['url'] as String?;
        final from = payload['forwarding_from'] as String?;
        return RelayNotification(
          title: 'Email forwarding confirmation',
          body: [
            if (from != null) 'Forwarding from $from',
            if (code != null) 'Code: $code',
            ?url,
            if (from == null) 'From $sender',
          ].join('\n'),
          code: code,
          url: confirmationUri(url),
        );
      case 'otp':
      default:
        final otp = payload['otp'] as String? ?? '??????';
        final marker = payload['verified'] == false ? ' (unverified)' : '';
        return RelayNotification(
          title: 'OTP from $sender$marker',
          body: otp,
          code: otp,
        );
    }
  }

  final String title;
  final String body;

  /// Offered through the "Copy code" action, when present.
  final String? code;

  /// Opened by tapping the notification, when present. Only ever a Gmail
  /// forwarding confirmation link (see [confirmationUri]).
  final Uri? url;

  /// Hosts Gmail sends forwarding confirmation links from. The server only
  /// passes these on from mail with a valid google.com DKIM signature; the
  /// app checks again, so a link it opens can only lead to Google.
  static const confirmationHosts = {
    'mail.google.com',
    'mail-settings.google.com',
  };

  /// [url] as a link the app may open, or null.
  @visibleForTesting
  static Uri? confirmationUri(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !confirmationHosts.contains(uri.host)) {
      return null;
    }
    return uri;
  }
}

/// Opens a link outside the app. Returns whether it did.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _openExternally(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Codes for the "Copy code" action, kept in memory by notification ID so the
/// code never becomes the plugin's payload. Nothing here is written to disk, so
/// after a restart the action finds nothing and does nothing.
@visibleForTesting
class NotificationCodes {
  NotificationCodes({this.lifetime = codeLifetime});

  /// As long as a desktop holds a code (`DesktopDeliveryService._holdFor`): the
  /// server's 10 minute limit plus up to 5 until its pruner runs. A code is no
  /// use after that, so the action stops offering it.
  static const codeLifetime = Duration(minutes: 15);

  final Duration lifetime;
  final Map<int, String> _codes = {};
  final Map<int, Timer> _expiry = {};

  int get length => _codes.length;

  void put(int id, String code) {
    _expiry.remove(id)?.cancel();
    _codes[id] = code;
    _expiry[id] = Timer(lifetime, () => remove(id));
  }

  /// The code for [id], if it hasn't expired. Removes it: the notification has
  /// been answered, which closes it.
  String? take(int id) {
    final code = _codes[id];
    remove(id);
    return code;
  }

  void remove(int id) {
    _expiry.remove(id)?.cancel();
    _codes.remove(id);
  }
}

class NotificationService {
  NotificationService._([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// For platforms whose plugin can't be faked through a method channel.
  @visibleForTesting
  factory NotificationService.forTesting(
    FlutterLocalNotificationsPlugin plugin,
  ) => NotificationService._(plugin);

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin;
  int _sequence = 0;

  @visibleForTesting
  final NotificationCodes codes = NotificationCodes();

  /// Opens a tapped notification's link.
  @visibleForTesting
  UrlOpener openUrl = _openExternally;

  /// Where the "Copy code" action finds its code.
  ///
  /// - Android: in the payload. The system keeps it in the action's intent, not
  ///   in a file, and the action can arrive after the process that showed the
  ///   notification (often the FCM background isolate) has gone.
  /// - Linux: in [codes]. The plugin writes every payload to
  ///   `notification_plugin_cache.json` under `$XDG_RUNTIME_DIR`, a file this
  ///   app doesn't control. Desktop codes only arrive while the app runs, and
  ///   the action is answered by the same process, so memory is enough.
  /// - Elsewhere there is no action, so the code isn't passed on at all. macOS
  ///   would keep it in the notification's userInfo, and Windows in the toast's
  ///   launch arguments.
  ///
  /// A link goes in the payload everywhere: the body already shows it, so the
  /// system holds it either way.
  static bool get _codeInPayload =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _codeInMemory =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  /// Sets up the plugin, here and in the FCM background isolate. Never asks for
  /// permission: the plugin would by default, before the first frame, with no
  /// word of why. NotificationExplainer does that, through
  /// NotificationPermissions.ask.
  Future<void> init() async {
    const android = AndroidInitializationSettings('@drawable/ic_stat_pux');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linux = LinuxInitializationSettings(
      defaultActionName: 'Open notification',
    );
    const windows = WindowsInitializationSettings(
      appName: 'pux',
      appUserModelId: 'xyz.vidur.pux',
      guid: 'a4d8b6ca-6b60-4901-9d08-5d79686765f4',
    );

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onResponse,
    );

    // Not available in the FCM background isolate on every platform.
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        await _onResponse(response);
      }
    } catch (error) {
      debugPrint('Notification launch details unavailable: $error');
    }
  }

  /// Decrypts and shows an encrypted envelope. Returns false when the
  /// envelope could not be decrypted, so callers do not acknowledge it.
  Future<bool> handleEncryptedMessage(Map<String, dynamic> data) async {
    final notification = await decrypt(data);
    if (notification == null) return false;

    await show(notification);
    return true;
  }

  /// Decrypts an envelope, or returns null if that isn't possible.
  Future<RelayNotification?> decrypt(Map<String, dynamic> data) async {
    final ciphertext = data['ciphertext'] as String?;
    if (ciphertext == null) {
      debugPrint('Ignoring envelope without ciphertext');
      return null;
    }

    try {
      final payload = await CryptoService.instance.decryptPayload(ciphertext);
      return RelayNotification.fromPayload(payload);
    } catch (error, stackTrace) {
      debugPrint('Failed to decrypt envelope: $error\n$stackTrace');
      return null;
    }
  }

  Future<void> show(RelayNotification notification) async {
    final androidDetails = AndroidNotificationDetails(
      'pux_otp',
      'OTP codes',
      channelDescription: 'Decrypted OTP notifications from pux',
      importance: Importance.max,
      priority: Priority.high,
      // On a secure lock screen Android shows only "pux" with the contents
      // hidden. flutter_local_notifications cannot set a custom public version.
      visibility: NotificationVisibility.private,
      // Collapsed, Android shows only the first line; a forwarding
      // confirmation's code and link come after it.
      styleInformation: BigTextStyleInformation(notification.body),
      actions: [
        if (notification.code != null)
          const AndroidNotificationAction(
            _copyActionId,
            'Copy code',
            showsUserInterface: true,
          ),
      ],
    );
    const darwinDetails = DarwinNotificationDetails();
    final linuxDetails = LinuxNotificationDetails(
      actions: [
        if (notification.code != null)
          const LinuxNotificationAction(key: _copyActionId, label: 'Copy code'),
      ],
    );
    const windowsDetails = WindowsNotificationDetails();

    final id = _nextId();
    final code = notification.code;
    if (code != null && _codeInMemory) codes.put(id, code);

    try {
      await _plugin.show(
        id: id,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
          linux: linuxDetails,
          windows: windowsDetails,
        ),
        payload: _payload(
          code: _codeInPayload ? code : null,
          url: notification.url,
        ),
      );
    } catch (_) {
      codes.remove(id);
      rethrow;
    }
  }

  /// Unique per notification, so codes arriving in the same second do not
  /// replace each other.
  int _nextId() =>
      (DateTime.now().millisecondsSinceEpoch + _sequence++) & 0x7fffffff;

  Future<void> _onResponse(NotificationResponse response) async {
    final id = response.id;
    final payload = _readPayload(response.payload);
    // Outside Android the payload never carries a code, so none is read from
    // it. A Linux notification left from before a restart finds nothing in
    // memory and copies nothing.
    final code = _codeInPayload
        ? payload.code
        : (id == null ? null : codes.take(id));

    if (response.actionId == _copyActionId) {
      if (code != null && code.isNotEmpty) {
        await SensitiveClipboard.instance.copy(code);
      }
    } else if (response.actionId == null || response.actionId!.isEmpty) {
      final url = payload.url;
      if (url != null) {
        await _open(url);
      } else {
        // The window may be hidden in the menu bar; the tap means "show me".
        await DesktopShell.instance.showWindow();
      }
    }
  }

  Future<void> _open(Uri url) async {
    try {
      if (!await openUrl(url)) debugPrint('No app opened the link');
    } catch (error) {
      debugPrint('Failed to open the link: $error');
    }
  }

  /// JSON with `code` and `url` when either is set, or null.
  static String? _payload({String? code, Uri? url}) {
    if (code == null && url == null) return null;
    return jsonEncode({'code': ?code, 'url': ?url?.toString()});
  }

  /// Reads [_payload]'s output. Android notifications from older builds carry
  /// the bare code. The link is checked again: the payload comes back from the
  /// system, and Linux keeps it in a file this app doesn't control.
  static ({String? code, Uri? url}) _readPayload(String? payload) {
    if (payload == null || payload.isEmpty) return (code: null, url: null);
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code'];
        final url = decoded['url'];
        return (
          code: code is String ? code : null,
          url: url is String ? RelayNotification.confirmationUri(url) : null,
        );
      }
    } on FormatException {
      // A bare code.
    }
    return (code: payload, url: null);
  }
}
