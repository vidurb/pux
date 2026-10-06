import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/notification_service.dart';

void main() {
  group('RelayNotification.fromPayload', () {
    test('renders an OTP', () {
      final n = RelayNotification.fromPayload({
        'type': 'otp',
        'otp': '482913',
        'sender': 'HDFC Bank',
      });
      expect(n.title, 'OTP from HDFC Bank');
      expect(n.body, '482913');
      expect(n.code, '482913');
    });

    test('treats payloads without a type as OTPs', () {
      final n = RelayNotification.fromPayload({'otp': '123456', 'sender': 'ICICI'});
      expect(n.title, 'OTP from ICICI');
      expect(n.code, '123456');
    });

    test('renders a forwarding confirmation', () {
      final n = RelayNotification.fromPayload({
        'type': 'forward_confirm',
        'code': '816235124',
        'url': 'https://mail.google.com/mail/vf-abc',
        'sender': 'forwarding-noreply@google.com',
      });
      expect(n.title, 'Email forwarding confirmation');
      expect(n.body, contains('Code: 816235124'));
      expect(n.body, contains('https://mail.google.com/mail/vf-abc'));
      expect(n.code, '816235124');
    });

    test('forwarding confirmation names the forwarding account', () {
      final n = RelayNotification.fromPayload({
        'type': 'forward_confirm',
        'code': null,
        'url': 'https://mail-settings.google.com/mail/vf-abc',
        'sender': 'Gmail',
        'forwarding_from': 'someone@gmail.com',
        'received_at': '2026-10-06T00:00:00Z',
      });
      expect(n.body, contains('Forwarding from someone@gmail.com'));
      expect(n.body, contains('https://mail-settings.google.com/mail/vf-abc'));
      expect(n.code, isNull);
    });

    test('forwarding confirmation without a code has nothing to copy', () {
      final n = RelayNotification.fromPayload({
        'type': 'forward_confirm',
        'url': 'https://example.test/confirm',
      });
      expect(n.code, isNull);
      expect(n.body, contains('https://example.test/confirm'));
    });
  });
}
