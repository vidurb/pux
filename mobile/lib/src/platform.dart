import 'package:flutter/foundation.dart';

bool get isDesktopPlatform {
  if (kIsWeb) return false;

  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

bool get isMobilePlatform {
  if (kIsWeb) return false;

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}

bool get supportsFirebasePush {
  if (kIsWeb) return false;

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}
