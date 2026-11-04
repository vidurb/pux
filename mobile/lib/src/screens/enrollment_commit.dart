import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../services/delivery_controller.dart';
import 'home_screen.dart';

/// Runs the step that commits an enrollment, for the screens that start one.
///
/// While it runs, [enrollmentPopScope] and the hidden back button keep the user
/// on the screen, so a failure can be shown in place. Backing out couldn't
/// cancel it anyway: the server may already have created the relay. The wait
/// is short and bounded by the API client's timeout.
///
/// The outcome doesn't depend on the screen staying, though. If it is disposed
/// anyway, a success still updates the app and a failure still shows.
mixin EnrollmentCommit<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _committing = false;

  /// Whether a commit is running, so the screen can show progress.
  bool get committing => _committing;

  /// The message for the screen to show. Screens also set it for their own
  /// errors, such as an unreadable QR code.
  String? enrollmentError;

  /// Keeps the user on the screen while a commit runs.
  Widget enrollmentPopScope({required Widget child}) =>
      PopScope(canPop: !_committing, child: child);

  /// Runs [save], then starts delivery and shows the home screen. Returns
  /// whether the device is now enrolled.
  Future<bool> commitEnrollment(Future<void> Function() save) async {
    // Resolved now because `ref` and `context` throw once the screen is
    // disposed. What they lead to lives as long as the app.
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _committing = true;
      enrollmentError = null;
    });

    try {
      await save();
    } catch (error) {
      if (mounted) {
        setState(() {
          _committing = false;
          enrollmentError = error.toString();
        });
      } else {
        messenger.showSnackBar(SnackBar(content: Text('Enrollment failed: $error')));
      }
      return false;
    }

    // Push registration runs in the background; the home screen shows its
    // progress and any failure.
    unawaited(DeliveryController.instance.start());
    container.invalidate(enrollmentProvider);
    unawaited(
      navigator.pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
        (_) => false,
      ),
    );
    return true;
  }
}
