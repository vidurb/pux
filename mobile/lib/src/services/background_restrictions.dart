import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Settings that stop codes reaching the user, or let them arrive unnoticed.
/// The home screen offers to fix each one, and lets the user dismiss it.
enum DeliveryRestriction {
  /// Android 12+ hibernates the app after a few months without use. Android 11
  /// and the backport to older versions only reset runtime permissions, which
  /// doesn't stop pushes, so those don't count.
  hibernation,

  /// The user set the app's battery usage to Restricted.
  backgroundUse,

  /// Android 8+: the `pux_otp` channel is on, but below high importance, so
  /// codes don't pop up on screen and may make no sound. Read by
  /// `NotificationPermissions`, like the rest of the channel's state.
  quietChannel,

  /// iOS 15+: pux's notifications go to the scheduled summary, so a code waits
  /// for the next summary instead of arriving when it's sent. pux doesn't mark
  /// them time-sensitive, so nothing lets a code break through. Read by
  /// `NotificationPermissions`.
  scheduledSummary,
}

/// What a check found. A restriction in neither set couldn't be determined.
class DeliveryRestrictionStatus {
  const DeliveryRestrictionStatus({
    this.active = const {},
    this.clear = const {},
  });

  final Set<DeliveryRestriction> active;
  final Set<DeliveryRestriction> clear;
}

/// Reads the battery and hibernation restrictions from Android. Other
/// platforms don't have them, and never touch the channel.
class BackgroundRestrictions {
  BackgroundRestrictions._();

  static final BackgroundRestrictions instance = BackgroundRestrictions._();

  @visibleForTesting
  static const channel = MethodChannel('xyz.vidur.pux/background_restrictions');

  Future<DeliveryRestrictionStatus> check() async {
    if (!_supported) return const DeliveryRestrictionStatus();

    final Map<String, Object?>? status;
    try {
      status = await channel.invokeMapMethod<String, Object?>('getStatus');
    } on MissingPluginException {
      return const DeliveryRestrictionStatus();
    } on PlatformException catch (error) {
      debugPrint('Could not read background restrictions: $error');
      return const DeliveryRestrictionStatus();
    }

    final hibernating = switch (status?['hibernation']) {
      'hibernation' => true,
      'permissionReset' || 'off' || 'unavailable' => false,
      _ => null,
    };
    final restricted = status?['backgroundRestricted'] as bool?;

    return DeliveryRestrictionStatus(
      active: {
        if (hibernating == true) DeliveryRestriction.hibernation,
        if (restricted == true) DeliveryRestriction.backgroundUse,
      },
      clear: {
        if (hibernating == false) DeliveryRestriction.hibernation,
        if (restricted == false) DeliveryRestriction.backgroundUse,
      },
    );
  }

  /// Opens the settings page that lifts [restriction]. Returns whether it opened.
  Future<bool> openSettings(DeliveryRestriction restriction) async {
    if (!_supported) return false;

    try {
      final method = switch (restriction) {
        DeliveryRestriction.hibernation => 'openHibernationSettings',
        DeliveryRestriction.backgroundUse => 'openAppSettings',
        // Notification settings, opened by NotificationPermissions.
        DeliveryRestriction.quietChannel ||
        DeliveryRestriction.scheduledSummary => null,
      };
      if (method == null) return false;
      final opened = await channel.invokeMethod<bool>(method);
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('Could not open settings: $error');
      return false;
    }
  }

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
