import 'delivery_service.dart';
import 'desktop_delivery_service.dart';
import 'push_service.dart';
import '../platform.dart';

DeliveryService deliveryServiceForPlatform() {
  if (isDesktopPlatform) {
    return DesktopDeliveryService.instance;
  }
  return PushService.instance;
}
