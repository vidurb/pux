abstract class DeliveryService {
  /// Registers this device and starts receiving. Throws on failure; the
  /// caller retries. Must be safe to call more than once.
  Future<void> init();

  Future<void> stop();
}
