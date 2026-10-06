import 'firebase_options.dart';

/// Whether real Firebase options were compiled in, either from a
/// `flutterfire configure` generated `firebase_options.dart` or from
/// `--dart-define=FIREBASE_*`. The checked-in file defaults to `REPLACE_ME`.
bool get firebaseConfigured {
  try {
    final options = DefaultFirebaseOptions.currentPlatform;
    return !options.apiKey.contains('REPLACE_ME') && !options.appId.contains('REPLACE_ME');
  } on UnsupportedError {
    return false;
  }
}

class FirebaseNotConfiguredException implements Exception {
  const FirebaseNotConfiguredException();

  @override
  String toString() =>
      'Firebase is not configured in this build, so push notifications are off. '
      'Rebuild after running flutterfire configure.';
}
