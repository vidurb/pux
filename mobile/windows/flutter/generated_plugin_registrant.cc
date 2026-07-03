//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <firebase_core/firebase_core_plugin_c_api.h>
#include <flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h>
#include <no_screenshot/no_screenshot_plugin_c_api.h>
#include <sodium_libs/sodium_libs_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FirebaseCorePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FirebaseCorePluginCApi"));
  FlutterSecureStorageWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterSecureStorageWindowsPlugin"));
  NoScreenshotPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("NoScreenshotPluginCApi"));
  SodiumLibsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SodiumLibsPluginCApi"));
}
