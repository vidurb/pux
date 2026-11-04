import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copies secrets (codes, enrollment JSON). Android and macOS mark the clip
/// sensitive natively, hiding it from clipboard previews and managers. Every
/// platform but iOS then clears the clipboard after [clearAfter] if it still
/// holds what we put there (best effort; iOS would prompt to read it back).
class SensitiveClipboard {
  SensitiveClipboard._();

  static final SensitiveClipboard instance = SensitiveClipboard._();

  static const clearAfter = Duration(seconds: 60);

  @visibleForTesting
  static const channel = MethodChannel('xyz.vidur.pux/clipboard');

  Timer? _clearTimer;

  Future<void> copy(String text) async {
    _clearTimer?.cancel();
    _clearTimer = null;

    if (_hasNativeSupport) {
      try {
        await channel.invokeMethod<void>('copySensitive', {
          'text': text,
          'clearAfterMs': clearAfter.inMilliseconds,
        });
        return;
      } on MissingPluginException {
        // Not registered in this engine (e.g. a background isolate).
      } on PlatformException catch (error) {
        debugPrint('Sensitive copy failed, using the plain clipboard: $error');
      }
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      _clearTimer = Timer(clearAfter, () => unawaited(_clearIfUnchanged(text)));
    }
  }

  Future<void> _clearIfUnchanged(String text) async {
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (error) {
      debugPrint('Clipboard clear failed: $error');
    }
  }

  bool get _hasNativeSupport =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);
}
