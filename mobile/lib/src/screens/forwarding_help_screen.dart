import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A bank's OTP email, as seen in a user's inbox, for building a filter.
class OtpSender {
  const OtpSender({
    required this.bank,
    required this.from,
    required this.subject,
  });

  final String bank;
  final String from;
  final String subject;
}

/// Known OTP senders. Keep in step with the README's forwarding section.
const knownOtpSenders = [
  OtpSender(
    bank: 'HSBC (credit card)',
    from: 'hsbc@hsbc.bank.in',
    subject: 'Your HSBC Credit Card OTP',
  ),
  OtpSender(
    bank: 'RBL Bank',
    from: 'alerts@rbl.bank.in',
    subject: 'One-Time Password for your online transaction',
  ),
];

/// Explains how to forward only bank OTP emails to the relay's inbox address.
class ForwardingHelpScreen extends StatelessWidget {
  const ForwardingHelpScreen({super.key, this.inbox});

  final String? inbox;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = inbox ?? 'your inbox address';

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(text, style: theme.textTheme.titleMedium),
    );

    Widget steps(List<String> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, item) in items.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 24, child: Text('${i + 1}.')),
                Expanded(child: Text(item)),
              ],
            ),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Set up forwarding')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            "Forward only your bank's OTP emails, not your whole mailbox. Set "
            'up a filter in your email account that matches the sender and '
            'subject of those emails and forwards them to your inbox address.',
          ),
          if (inbox != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: SelectableText(inbox!)),
                IconButton(
                  tooltip: 'Copy inbox address',
                  icon: const Icon(Icons.copy),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: inbox!)),
                ),
              ],
            ),
          ],
          heading('Gmail'),
          const Text(
            'Filters can only be created on gmail.com in a browser, not in the Gmail app.',
          ),
          const SizedBox(height: 8),
          steps([
            'Open Settings → See all settings → Forwarding and POP/IMAP.',
            'Choose "Add a forwarding address" and enter $address.',
            'Gmail sends a confirmation to that address. It arrives in pux as '
                'a notification with the code; enter it in Gmail to verify. '
                'Leave forwarding itself disabled.',
            'In the search bar, open the search options. Fill in From and '
                'Subject with the values for your bank (see below), then '
                'choose "Create filter".',
            'Tick "Forward it to", pick your inbox address, and create the filter.',
          ]),
          heading('Outlook.com'),
          steps([
            'Open Settings → Mail → Rules → Add new rule.',
            'Add the conditions "From" and "Subject includes" with the values '
                'for your bank (see below).',
            'Add the action "Redirect to" and enter $address. Use Redirect '
                'rather than Forward, so the bank stays the sender and its '
                'name can be verified.',
          ]),
          heading('Other providers'),
          const Text(
            'Most providers support rules or filters that forward matching '
            'mail. Prefer an option that keeps the original sender (often '
            'called redirect). If your bank appears as unverified in pux, the '
            'forwarding changed the message.',
          ),
          heading('Known bank OTP emails'),
          const Text(
            'Check an OTP email in your own inbox first: banks use different '
            'senders for different products and change them over time.',
          ),
          const SizedBox(height: 8),
          for (final sender in knownOtpSenders)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sender.bank, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    SelectableText('From: ${sender.from}'),
                    SelectableText('Subject: ${sender.subject}'),
                  ],
                ),
              ),
            ),
          heading('Test it'),
          const Text(
            'To check the relay, email "Your OTP is 123456" straight to your '
            'inbox address; a notification should arrive within a few '
            'seconds. Your next bank OTP checks the filter itself.',
          ),
        ],
      ),
    );
  }
}
