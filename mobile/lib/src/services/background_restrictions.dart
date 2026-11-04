import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android settings that silently stop FCM pushes from reaching the app.
enum DeliveryRestriction {
  /// Android 12+ hibernates the app after a few months without use. Android 11
  /// and the backport to older versions only reset runtime permissions, which
  /// doesn't stop pushes, so those don't count.
  hibernation,

  /// The user set the app's battery usage to Restricted.
  backgroundUse,
}

/// What a check found. A restriction in neither set couldn't be determined.
class BackgroundRestrictionStatus {
  const BackgroundRestrictionStatus({this.active = const {}, this.clear = const {}});

  final Set<DeliveryRestriction> active;
  final Set<DeliveryRestriction> clear;
}

/// Reads the restrictions from Android. Other platforms don't have them, and
/// never touch the channel.
class BackgroundRestrictions {
  BackgroundRestrictions._();

  static final BackgroundRestrictions instance = BackgroundRestrictions._();

  @visibleForTesting
  static const channel = MethodChannel('xyz.vidur.pux/background_restrictions');

  Future<BackgroundRestrictionStatus> check() async {
    if (!_supported) return const BackgroundRestrictionStatus();

    final Map<String, Object?>? status;
    try {
      status = await channel.invokeMapMethod<String, Object?>('getStatus');
    } on MissingPluginException {
      return const BackgroundRestrictionStatus();
    } on PlatformException catch (error) {
      debugPrint('Could not read background restrictions: $error');
      return const BackgroundRestrictionStatus();
    }

    final hibernating = switch (status?['hibernation']) {
      'hibernation' => true,
      'permissionReset' || 'off' || 'unavailable' => false,
      _ => null,
    };
    final restricted = status?['backgroundRestricted'] as bool?;

    return BackgroundRestrictionStatus(
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
      final opened = await channel.invokeMethod<bool>(switch (restriction) {
        DeliveryRestriction.hibernation => 'openHibernationSettings',
        DeliveryRestriction.backgroundUse => 'openAppSettings',
      });
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('Could not open settings: $error');
      return false;
    }
  }

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
