import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../services/crypto_service.dart';
import '../services/record_store.dart';
import 'enrollment_commit.dart';

class CreateRelayScreen extends ConsumerStatefulWidget {
  const CreateRelayScreen({super.key});

  @override
  ConsumerState<CreateRelayScreen> createState() => _CreateRelayScreenState();
}

class _CreateRelayScreenState extends ConsumerState<CreateRelayScreen>
    with EnrollmentCommit<CreateRelayScreen> {
  Future<void> _createRelay() async {
    if (committing) return;
    await commitEnrollment(() async {
      final keys = await CryptoService.instance.generateKeyPair();
      final record = await ApiClient.instance.createRecord(publicKey: keys['public_key']!);

      try {
        await RecordStore.instance.saveEnrollment({
          'record_id': record['record_id'],
          'private_key': keys['private_key'],
          'public_key': keys['public_key'],
          'inbox': record['inbox_address'],
          'server': RecordStore.instance.serverUrl,
        });
      } catch (_) {
        await _deleteUnsavedRelay(record['record_id']!);
        rethrow;
      }
    });
  }

  /// This device was the only holder of the new relay's ID, so without the save
  /// nobody could ever use the relay. If the delete fails too, the server
  /// prunes it, since no device ever registered on it.
  Future<void> _deleteUnsavedRelay(String recordId) async {
    try {
      await ApiClient.instance.deleteRecord(recordId: recordId);
    } catch (_) {
      // Not logged: the error can include the URL, and the record ID is a credential.
      debugPrint('Could not delete a relay that was not saved on this device');
    }
  }

  @override
  Widget build(BuildContext context) {
    return enrollmentPopScope(
      child: Scaffold(
        appBar: AppBar(title: const Text('Create relay'), automaticallyImplyLeading: !committing),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'A new encryption keypair will be generated on this device. '
                'Only the public key is sent to the server.',
              ),
              const SizedBox(height: 24),
              if (committing) const LinearProgressIndicator(),
              FilledButton(
                onPressed: committing ? null : _createRelay,
                child: const Text('Generate keys and create relay'),
              ),
              if (enrollmentError != null) ...[
                const SizedBox(height: 16),
                Text(enrollmentError!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
