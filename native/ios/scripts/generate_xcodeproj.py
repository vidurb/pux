#!/usr/bin/env python3
import hashlib
import os

PROJECT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO_ROOT = os.path.abspath(os.path.join(PROJECT_DIR, "../.."))
PBX_PATH = os.path.join(PROJECT_DIR, "Pux.xcodeproj", "project.pbxproj")

def make_id(name: str) -> str:
    h = hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()
    return h

def get_marketing_version() -> str:
    if "MARKETING_VERSION" in os.environ:
        return os.environ["MARKETING_VERSION"]
    pubspec = os.path.join(REPO_ROOT, "mobile", "pubspec.yaml")
    if os.path.exists(pubspec):
        with open(pubspec, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("version:"):
                    parts = line.split(":", 1)[1].split("#")[0].strip()
                    return parts
    return "0.1.0"

def get_build_number() -> str:
    return os.environ.get("CURRENT_PROJECT_VERSION", os.environ.get("BUILD_NUMBER", "1"))

def generate():
    # File references
    puxcore_files = [
        ("Base64URL.swift", "Sources/PuxCore/Extensions/Base64URL.swift"),
        ("String+UUID.swift", "Sources/PuxCore/Extensions/String+UUID.swift"),
        ("EnrollmentPayload.swift", "Sources/PuxCore/Models/EnrollmentPayload.swift"),
        ("EnrollmentImportAccessibility.swift", "Sources/PuxCore/Models/EnrollmentImportAccessibility.swift"),
        ("Errors.swift", "Sources/PuxCore/Models/Errors.swift"),
        ("FirebaseConfig.swift", "Sources/PuxCore/Models/FirebaseConfig.swift"),
        ("RelayNotification.swift", "Sources/PuxCore/Models/RelayNotification.swift"),
        ("DeliveryStatus.swift", "Sources/PuxCore/Models/DeliveryStatus.swift"),
        ("ServerHealth.swift", "Sources/PuxCore/Models/ServerHealth.swift"),
        ("TestCode.swift", "Sources/PuxCore/Models/TestCode.swift"),
        ("KnownSenders.swift", "Sources/PuxCore/Models/KnownSenders.swift"),
        ("AppBootstrap.swift", "Sources/PuxCore/Services/AppBootstrap.swift"),
        ("CryptoService.swift", "Sources/PuxCore/Services/CryptoService.swift"),
        ("PuxKeychain.swift", "Sources/PuxCore/Services/PuxKeychain.swift"),
        ("RecordStore.swift", "Sources/PuxCore/Services/RecordStore.swift"),
        ("ApiClient.swift", "Sources/PuxCore/Services/ApiClient.swift"),
        ("DeliveryController.swift", "Sources/PuxCore/Services/DeliveryController.swift"),
        ("FcmRegistration.swift", "Sources/PuxCore/Services/FcmRegistration.swift"),
        ("RegisterAsyncBridge.swift", "Sources/PuxCore/Services/RegisterAsyncBridge.swift"),
        ("NotificationPermissions.swift", "Sources/PuxCore/Services/NotificationPermissions.swift"),
        ("SensitiveClipboard.swift", "Sources/PuxCore/Services/SensitiveClipboard.swift"),
    ]

    puxapp_files = [
        ("PuxApp.swift", "Sources/PuxApp/PuxApp.swift"),
        ("AppDelegate.swift", "Sources/PuxApp/AppDelegate.swift"),
        ("PuxTheme.swift", "Sources/PuxApp/PuxTheme.swift"),
        ("NativeFirebaseRegistrationSource.swift", "Sources/PuxApp/Services/NativeFirebaseRegistrationSource.swift"),
        ("ConfirmServerAlert.swift", "Sources/PuxApp/Views/ConfirmServerAlert.swift"),
        ("ContentView.swift", "Sources/PuxApp/Views/ContentView.swift"),
        ("CreateRelayScreen.swift", "Sources/PuxApp/Views/CreateRelayScreen.swift"),
        ("DeleteRelayDialog.swift", "Sources/PuxApp/Views/DeleteRelayDialog.swift"),
        ("DeliveryBannerView.swift", "Sources/PuxApp/Views/DeliveryBannerView.swift"),
        ("DeliveryPromptView.swift", "Sources/PuxApp/Views/DeliveryPromptView.swift"),
        ("EnrollChooserScreen.swift", "Sources/PuxApp/Views/EnrollChooserScreen.swift"),
        ("EnrollScreen.swift", "Sources/PuxApp/Views/EnrollScreen.swift"),
        ("ForwardingHelpScreen.swift", "Sources/PuxApp/Views/ForwardingHelpScreen.swift"),
        ("HomeScreen.swift", "Sources/PuxApp/Views/HomeScreen.swift"),
        ("ImportEnrollmentScreen.swift", "Sources/PuxApp/Views/ImportEnrollmentScreen.swift"),
        ("NotificationExplainerView.swift", "Sources/PuxApp/Views/NotificationExplainerView.swift"),
        ("QRCodeView.swift", "Sources/PuxApp/Views/QRCodeView.swift"),
        ("QRScannerView.swift", "Sources/PuxApp/Views/QRScannerView.swift"),
        ("ServerStatusView.swift", "Sources/PuxApp/Views/ServerStatusView.swift"),
        ("TestCodeDialog.swift", "Sources/PuxApp/Views/TestCodeDialog.swift"),
        ("PuxStackNavigation.swift", "Sources/PuxApp/Views/PuxStackNavigation.swift"),
    ]

    nse_files = [
        ("NotificationService.swift", "Sources/NotificationService/NotificationService.swift"),
    ]

    test_files = [
        ("MockURLProtocol.swift", "Tests/PuxCoreTests/MockURLProtocol.swift"),
        ("CryptoServiceTests.swift", "Tests/PuxCoreTests/CryptoServiceTests.swift"),
        ("RecordStoreTests.swift", "Tests/PuxCoreTests/RecordStoreTests.swift"),
        ("ApiClientTests.swift", "Tests/PuxCoreTests/ApiClientTests.swift"),
        ("RelayNotificationTests.swift", "Tests/PuxCoreTests/RelayNotificationTests.swift"),
        ("DeliveryControllerTests.swift", "Tests/PuxCoreTests/DeliveryControllerTests.swift"),
        ("FcmRegistrationTests.swift", "Tests/PuxCoreTests/FcmRegistrationTests.swift"),
        ("RegisterAsyncBridgeTests.swift", "Tests/PuxCoreTests/RegisterAsyncBridgeTests.swift"),
        ("KeychainMigrationTests.swift", "Tests/PuxCoreTests/KeychainMigrationTests.swift"),
        ("MockPuxKeychainBackend.swift", "Tests/PuxCoreTests/MockPuxKeychainBackend.swift"),
        ("EnrollmentPayloadVersionTests.swift", "Tests/PuxCoreTests/EnrollmentPayloadVersionTests.swift"),
        ("RecordStoreProtectedDataTests.swift", "Tests/PuxCoreTests/RecordStoreProtectedDataTests.swift"),
        ("SpyPuxKeychainBackend.swift", "Tests/PuxCoreTests/SpyPuxKeychainBackend.swift"),
        ("RecordStoreKeychainIsolationTests.swift", "Tests/PuxCoreTests/RecordStoreKeychainIsolationTests.swift"),
        ("AppBootstrapTests.swift", "Tests/PuxCoreTests/AppBootstrapTests.swift"),
        ("PuxKeychainDefaultBackendTests.swift", "Tests/PuxCoreTests/PuxKeychainDefaultBackendTests.swift"),
        ("EnrollmentImportAccessibilityTests.swift", "Tests/PuxCoreTests/EnrollmentImportAccessibilityTests.swift"),
    ]

    # IDs
    id_proj = make_id("PROJECT")
    id_main_group = make_id("MAIN_GROUP")
    id_products_group = make_id("PRODUCTS_GROUP")

    id_core_target = make_id("TARGET_CORE")
    id_app_target = make_id("TARGET_APP")
    id_nse_target = make_id("TARGET_NSE")
    id_test_target = make_id("TARGET_TESTS")

    id_core_product = make_id("PRODUCT_CORE")
    id_app_product = make_id("PRODUCT_APP")
    id_nse_product = make_id("PRODUCT_NSE")
    id_test_product = make_id("PRODUCT_TEST")

    id_pkg_sodium = make_id("PACKAGE_SODIUM")
    id_prod_sodium_core = make_id("PROD_SODIUM_CORE")
    id_prod_sodium_app = make_id("PROD_SODIUM_APP")
    id_prod_sodium_nse = make_id("PROD_SODIUM_NSE")
    id_prod_sodium_test = make_id("PROD_SODIUM_TEST")

    id_build_prod_sodium_core = make_id("BUILD_PROD_SODIUM_CORE")
    id_build_prod_sodium_app = make_id("BUILD_PROD_SODIUM_APP")
    id_build_prod_sodium_nse = make_id("BUILD_PROD_SODIUM_NSE")
    id_build_prod_sodium_test = make_id("BUILD_PROD_SODIUM_TEST")

    id_pkg_firebase = make_id("PACKAGE_FIREBASE")
    id_prod_firebase_app = make_id("PROD_FIREBASE_APP")
    id_build_prod_firebase_app = make_id("BUILD_PROD_FIREBASE_APP")

    # PuxCore in Frameworks of App, NSE, Test
    id_build_core_app = make_id("BUILD_CORE_APP")
    id_build_core_nse = make_id("BUILD_CORE_NSE")
    id_build_core_test = make_id("BUILD_CORE_TEST")

    # Embed extension phase
    id_embed_nse_phase = make_id("EMBED_NSE_PHASE")
    id_embed_nse_buildfile = make_id("EMBED_NSE_BUILDFILE")

    # Container Proxies & Target Dependencies
    id_proxy_core_app = make_id("PROXY_CORE_APP")
    id_proxy_core_nse = make_id("PROXY_CORE_NSE")
    id_proxy_core_test = make_id("PROXY_CORE_TEST")
    id_dep_core_app = make_id("DEP_CORE_APP")
    id_dep_core_nse = make_id("DEP_CORE_NSE")
    id_dep_core_test = make_id("DEP_CORE_TEST")

    id_proxy_nse_app = make_id("PROXY_NSE_APP")
    id_dep_nse_app = make_id("DEP_NSE_APP")

    id_proxy_app_test = make_id("PROXY_APP_TEST")
    id_dep_app_test = make_id("DEP_APP_TEST")

    # Assets & Plists
    id_assets_ref = make_id("FILE_Assets.xcassets")
    id_assets_build = make_id("BUILD_Assets.xcassets")
    id_gservice_ref = make_id("FILE_GoogleService-Info.plist")
    id_gservice_build = make_id("BUILD_GoogleService-Info.plist")

    id_app_plist = make_id("FILE_PuxApp_Info.plist")
    id_app_entitlements = make_id("FILE_Pux.entitlements")
    id_app_release_entitlements = make_id("FILE_PuxRelease.entitlements")
    id_nse_plist = make_id("FILE_NSE_Info.plist")
    id_nse_entitlements = make_id("FILE_NSE.entitlements")

    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")

    # PBXBuildFile
    out.append("\n/* Begin PBXBuildFile section */")
    out.append(f"\t\t{id_build_prod_sodium_core} /* Sodium in Frameworks */ = {{isa = PBXBuildFile; productRef = {id_prod_sodium_core} /* Sodium */; }};")
    out.append(f"\t\t{id_build_prod_sodium_app} /* Sodium in Frameworks */ = {{isa = PBXBuildFile; productRef = {id_prod_sodium_app} /* Sodium */; }};")
    out.append(f"\t\t{id_build_prod_firebase_app} /* FirebaseMessaging in Frameworks */ = {{isa = PBXBuildFile; productRef = {id_prod_firebase_app} /* FirebaseMessaging */; }};")
    out.append(f"\t\t{id_build_prod_sodium_nse} /* Sodium in Frameworks */ = {{isa = PBXBuildFile; productRef = {id_prod_sodium_nse} /* Sodium */; }};")
    out.append(f"\t\t{id_build_prod_sodium_test} /* Sodium in Frameworks */ = {{isa = PBXBuildFile; productRef = {id_prod_sodium_test} /* Sodium */; }};")

    out.append(f"\t\t{id_build_core_app} /* PuxCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {id_core_product} /* PuxCore.framework */; }};")
    out.append(f"\t\t{id_build_core_nse} /* PuxCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {id_core_product} /* PuxCore.framework */; }};")
    out.append(f"\t\t{id_build_core_test} /* PuxCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {id_core_product} /* PuxCore.framework */; }};")

    out.append(f"\t\t{id_assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {id_assets_ref} /* Assets.xcassets */; }};")
    out.append(f"\t\t{id_gservice_build} /* GoogleService-Info.plist in Resources */ = {{isa = PBXBuildFile; fileRef = {id_gservice_ref} /* GoogleService-Info.plist */; }};")
    out.append(f"\t\t{id_embed_nse_buildfile} /* NotificationService.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {id_nse_product} /* NotificationService.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")

    # Core sources
    core_build_files = []
    for name, path in puxcore_files:
        bf_id = make_id(f"BUILDFILE_CORE_{name}")
        fr_id = make_id(f"FILE_{path}")
        core_build_files.append((bf_id, name))
        out.append(f"\t\t{bf_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_id} /* {name} */; }};")

    # App sources
    app_build_files = []
    for name, path in puxapp_files:
        bf_id = make_id(f"BUILDFILE_APP_{name}")
        fr_id = make_id(f"FILE_{path}")
        app_build_files.append((bf_id, name))
        out.append(f"\t\t{bf_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_id} /* {name} */; }};")

    # NSE sources
    nse_build_files = []
    for name, path in nse_files:
        bf_id = make_id(f"BUILDFILE_NSE_{name}")
        fr_id = make_id(f"FILE_{path}")
        nse_build_files.append((bf_id, name))
        out.append(f"\t\t{bf_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_id} /* {name} */; }};")

    # Test sources
    test_build_files = []
    for name, path in test_files:
        bf_id = make_id(f"BUILDFILE_TEST_{name}")
        fr_id = make_id(f"FILE_{path}")
        test_build_files.append((bf_id, name))
        out.append(f"\t\t{bf_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_id} /* {name} */; }};")

    out.append("/* End PBXBuildFile section */")

    # PBXContainerItemProxy
    out.append("\n/* Begin PBXContainerItemProxy section */")
    out.append(f"\t\t{id_proxy_core_app} /* PBXContainerItemProxy */ = {{")
    out.append("\t\t\tisa = PBXContainerItemProxy;")
    out.append(f"\t\t\tcontainerPortal = {id_proj} /* Project object */;")
    out.append("\t\t\tproxyType = 1;")
    out.append(f"\t\t\tremoteGlobalIDString = {id_core_target};")
    out.append("\t\t\tremoteInfo = PuxCore;")
    out.append("\t\t};")

    out.append(f"\t\t{id_proxy_core_nse} /* PBXContainerItemProxy */ = {{")
    out.append("\t\t\tisa = PBXContainerItemProxy;")
    out.append(f"\t\t\tcontainerPortal = {id_proj} /* Project object */;")
    out.append("\t\t\tproxyType = 1;")
    out.append(f"\t\t\tremoteGlobalIDString = {id_core_target};")
    out.append("\t\t\tremoteInfo = PuxCore;")
    out.append("\t\t};")

    out.append(f"\t\t{id_proxy_core_test} /* PBXContainerItemProxy */ = {{")
    out.append("\t\t\tisa = PBXContainerItemProxy;")
    out.append(f"\t\t\tcontainerPortal = {id_proj} /* Project object */;")
    out.append("\t\t\tproxyType = 1;")
    out.append(f"\t\t\tremoteGlobalIDString = {id_core_target};")
    out.append("\t\t\tremoteInfo = PuxCore;")
    out.append("\t\t};")

    out.append(f"\t\t{id_proxy_nse_app} /* PBXContainerItemProxy */ = {{")
    out.append("\t\t\tisa = PBXContainerItemProxy;")
    out.append(f"\t\t\tcontainerPortal = {id_proj} /* Project object */;")
    out.append("\t\t\tproxyType = 1;")
    out.append(f"\t\t\tremoteGlobalIDString = {id_nse_target};")
    out.append("\t\t\tremoteInfo = NotificationService;")
    out.append("\t\t};")

    out.append(f"\t\t{id_proxy_app_test} /* PBXContainerItemProxy */ = {{")
    out.append("\t\t\tisa = PBXContainerItemProxy;")
    out.append(f"\t\t\tcontainerPortal = {id_proj} /* Project object */;")
    out.append("\t\t\tproxyType = 1;")
    out.append(f"\t\t\tremoteGlobalIDString = {id_app_target};")
    out.append("\t\t\tremoteInfo = Pux;")
    out.append("\t\t};")
    out.append("/* End PBXContainerItemProxy section */")

    # PBXCopyFilesBuildPhase
    out.append("\n/* Begin PBXCopyFilesBuildPhase section */")
    out.append(f"\t\t{id_embed_nse_phase} /* Embed Foundation Extensions */ = {{")
    out.append("\t\t\tisa = PBXCopyFilesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tdstPath = \"\";")
    out.append("\t\t\tdstSubfolderSpec = 13;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{id_embed_nse_buildfile} /* NotificationService.appex in Embed Foundation Extensions */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = \"Embed Foundation Extensions\";")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXCopyFilesBuildPhase section */")

    # PBXFileReference
    out.append("\n/* Begin PBXFileReference section */")
    out.append(f"\t\t{id_core_product} /* PuxCore.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = PuxCore.framework; sourceTree = BUILT_PRODUCTS_DIR; }};")
    out.append(f"\t\t{id_app_product} /* Pux.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Pux.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    out.append(f"\t\t{id_nse_product} /* NotificationService.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = NotificationService.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")
    out.append(f"\t\t{id_test_product} /* PuxTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = PuxTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")

    out.append(f"\t\t{id_assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Sources/PuxApp/Assets.xcassets; sourceTree = \"<group>\"; }};")
    out.append(f"\t\t{id_gservice_ref} /* GoogleService-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Sources/PuxApp/GoogleService-Info.plist; sourceTree = \"<group>\"; }};")

    # Sorted so regenerating the project is reproducible (set order varies per run).
    all_file_refs = sorted(set(puxcore_files + puxapp_files + nse_files + test_files), key=lambda f: f[1])
    for name, path in all_file_refs:
        fr_id = make_id(f"FILE_{path}")
        out.append(f"\t\t{fr_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{path}\"; sourceTree = \"<group>\"; }};")

    out.append(f"\t\t{id_app_plist} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Sources/PuxApp/Info.plist; sourceTree = \"<group>\"; }};")
    out.append(f"\t\t{id_app_entitlements} /* Pux.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Sources/PuxApp/Pux.entitlements; sourceTree = \"<group>\"; }};")
    out.append(f"\t\t{id_app_release_entitlements} /* PuxRelease.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Sources/PuxApp/PuxRelease.entitlements; sourceTree = \"<group>\"; }};")
    out.append(f"\t\t{id_nse_plist} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Sources/NotificationService/Info.plist; sourceTree = \"<group>\"; }};")
    out.append(f"\t\t{id_nse_entitlements} /* NotificationService.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Sources/NotificationService/NotificationService.entitlements; sourceTree = \"<group>\"; }};")

    out.append("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    id_frameworks_core = make_id("PHASE_FRAMEWORKS_CORE")
    id_frameworks_app = make_id("PHASE_FRAMEWORKS_APP")
    id_frameworks_nse = make_id("PHASE_FRAMEWORKS_NSE")
    id_frameworks_test = make_id("PHASE_FRAMEWORKS_TEST")

    out.append("\n/* Begin PBXFrameworksBuildPhase section */")
    out.append(f"\t\t{id_frameworks_core} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{id_build_prod_sodium_core} /* Sodium in Frameworks */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    out.append(f"\t\t{id_frameworks_app} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{id_build_core_app} /* PuxCore.framework in Frameworks */,")
    out.append(f"\t\t\t\t{id_build_prod_sodium_app} /* Sodium in Frameworks */,")
    out.append(f"\t\t\t\t{id_build_prod_firebase_app} /* FirebaseMessaging in Frameworks */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    out.append(f"\t\t{id_frameworks_nse} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{id_build_core_nse} /* PuxCore.framework in Frameworks */,")
    out.append(f"\t\t\t\t{id_build_prod_sodium_nse} /* Sodium in Frameworks */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    out.append(f"\t\t{id_frameworks_test} /* Frameworks */ = {{")
    out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{id_build_core_test} /* PuxCore.framework in Frameworks */,")
    out.append(f"\t\t\t\t{id_build_prod_sodium_test} /* Sodium in Frameworks */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    out.append("\n/* Begin PBXGroup section */")
    out.append(f"\t\t{id_main_group} = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    for name, path in all_file_refs:
        fr_id = make_id(f"FILE_{path}")
        out.append(f"\t\t\t\t{fr_id} /* {name} */,")
    out.append(f"\t\t\t\t{id_assets_ref} /* Assets.xcassets */,")
    out.append(f"\t\t\t\t{id_gservice_ref} /* GoogleService-Info.plist */,")
    out.append(f"\t\t\t\t{id_app_plist} /* Info.plist */,")
    out.append(f"\t\t\t\t{id_app_entitlements} /* Pux.entitlements */,")
    out.append(f"\t\t\t\t{id_app_release_entitlements} /* PuxRelease.entitlements */,")
    out.append(f"\t\t\t\t{id_nse_plist} /* Info.plist */,")
    out.append(f"\t\t\t\t{id_nse_entitlements} /* NotificationService.entitlements */,")
    out.append(f"\t\t\t\t{id_products_group} /* Products */,")
    out.append("\t\t\t);")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")

    out.append(f"\t\t{id_products_group} /* Products */ = {{")
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append(f"\t\t\t\t{id_core_product} /* PuxCore.framework */,")
    out.append(f"\t\t\t\t{id_app_product} /* Pux.app */,")
    out.append(f"\t\t\t\t{id_nse_product} /* NotificationService.appex */,")
    out.append(f"\t\t\t\t{id_test_product} /* PuxTests.xctest */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = Products;")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    out.append("/* End PBXGroup section */")

    # Native Targets
    id_sources_core = make_id("PHASE_SOURCES_CORE")
    id_configs_core = make_id("CONFIGS_CORE")

    id_sources_app = make_id("PHASE_SOURCES_APP")
    id_resources_app = make_id("PHASE_RESOURCES_APP")
    id_configs_app = make_id("CONFIGS_APP")

    id_sources_nse = make_id("PHASE_SOURCES_NSE")
    id_resources_nse = make_id("PHASE_RESOURCES_NSE")
    id_configs_nse = make_id("CONFIGS_NSE")

    id_sources_test = make_id("PHASE_SOURCES_TEST")
    id_resources_test = make_id("PHASE_RESOURCES_TEST")
    id_configs_test = make_id("CONFIGS_TEST")

    out.append("\n/* Begin PBXNativeTarget section */")

    # PuxCore Framework Target
    out.append(f"\t\t{id_core_target} /* PuxCore */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(f"\t\t\tbuildConfigurationList = {id_configs_core} /* Build configuration list for PBXNativeTarget \"PuxCore\" */;")
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{id_sources_core} /* Sources */,")
    out.append(f"\t\t\t\t{id_frameworks_core} /* Frameworks */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append("\t\t\t);")
    out.append("\t\t\tname = PuxCore;")
    out.append("\t\t\tpackageProductDependencies = (")
    out.append(f"\t\t\t\t{id_prod_sodium_core} /* Sodium */,")
    out.append("\t\t\t);")
    out.append("\t\t\tproductName = PuxCore;")
    out.append(f"\t\t\tproductReference = {id_core_product} /* PuxCore.framework */;")
    out.append("\t\t\tproductType = \"com.apple.product-type.framework\";")
    out.append("\t\t};")

    # Pux App Target
    out.append(f"\t\t{id_app_target} /* Pux */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(f"\t\t\tbuildConfigurationList = {id_configs_app} /* Build configuration list for PBXNativeTarget \"Pux\" */;")
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{id_sources_app} /* Sources */,")
    out.append(f"\t\t\t\t{id_frameworks_app} /* Frameworks */,")
    out.append(f"\t\t\t\t{id_resources_app} /* Resources */,")
    out.append(f"\t\t\t\t{id_embed_nse_phase} /* Embed Foundation Extensions */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append(f"\t\t\t\t{id_dep_core_app} /* PBXTargetDependency */,")
    out.append(f"\t\t\t\t{id_dep_nse_app} /* PBXTargetDependency */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = Pux;")
    out.append(f"\t\t\tpackageProductDependencies = (")
    out.append(f"\t\t\t\t{id_prod_sodium_app} /* Sodium */,")
    out.append(f"\t\t\t\t{id_prod_firebase_app} /* FirebaseMessaging */,")
    out.append("\t\t\t);")
    out.append("\t\t\tproductName = Pux;")
    out.append(f"\t\t\tproductReference = {id_app_product} /* Pux.app */;")
    out.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    out.append("\t\t};")

    # NotificationService Extension Target
    out.append(f"\t\t{id_nse_target} /* NotificationService */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(f"\t\t\tbuildConfigurationList = {id_configs_nse} /* Build configuration list for PBXNativeTarget \"NotificationService\" */;")
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{id_sources_nse} /* Sources */,")
    out.append(f"\t\t\t\t{id_frameworks_nse} /* Frameworks */,")
    out.append(f"\t\t\t\t{id_resources_nse} /* Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append(f"\t\t\t\t{id_dep_core_nse} /* PBXTargetDependency */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = NotificationService;")
    out.append(f"\t\t\tpackageProductDependencies = (")
    out.append(f"\t\t\t\t{id_prod_sodium_nse} /* Sodium */,")
    out.append("\t\t\t);")
    out.append("\t\t\tproductName = NotificationService;")
    out.append(f"\t\t\tproductReference = {id_nse_product} /* NotificationService.appex */;")
    out.append("\t\t\tproductType = \"com.apple.product-type.app-extension\";")
    out.append("\t\t};")

    # PuxTests Target
    out.append(f"\t\t{id_test_target} /* PuxTests */ = {{")
    out.append("\t\t\tisa = PBXNativeTarget;")
    out.append(f"\t\t\tbuildConfigurationList = {id_configs_test} /* Build configuration list for PBXNativeTarget \"PuxTests\" */;")
    out.append("\t\t\tbuildPhases = (")
    out.append(f"\t\t\t\t{id_sources_test} /* Sources */,")
    out.append(f"\t\t\t\t{id_frameworks_test} /* Frameworks */,")
    out.append(f"\t\t\t\t{id_resources_test} /* Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\tbuildRules = (")
    out.append("\t\t\t);")
    out.append("\t\t\tdependencies = (")
    out.append(f"\t\t\t\t{id_dep_core_test} /* PBXTargetDependency */,")
    out.append(f"\t\t\t\t{id_dep_app_test} /* PBXTargetDependency */,")
    out.append("\t\t\t);")
    out.append("\t\t\tname = PuxTests;")
    out.append(f"\t\t\tpackageProductDependencies = (")
    out.append(f"\t\t\t\t{id_prod_sodium_test} /* Sodium */,")
    out.append("\t\t\t);")
    out.append("\t\t\tproductName = PuxTests;")
    out.append(f"\t\t\tproductReference = {id_test_product} /* PuxTests.xctest */;")
    out.append("\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
    out.append("\t\t};")
    out.append("/* End PBXNativeTarget section */")

    # PBXProject
    id_proj_configs = make_id("CONFIGS_PROJ")
    out.append("\n/* Begin PBXProject section */")
    out.append(f"\t\t{id_proj} /* Project object */ = {{")
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    out.append("\t\t\t\tLastUpgradeCheck = 1500;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append(f"\t\t\t\t\t{id_core_target} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append(f"\t\t\t\t\t{id_app_target} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append(f"\t\t\t\t\t{id_nse_target} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append("\t\t\t\t\t};")
    out.append(f"\t\t\t\t\t{id_test_target} = {{")
    out.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    out.append(f"\t\t\t\t\t\tTestTargetID = {id_app_target};")
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append(f"\t\t\tbuildConfigurationList = {id_proj_configs} /* Build configuration list for PBXProject \"Pux\" */;")
    out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    out.append("\t\t\tdevelopmentRegion = en;")
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\ten,")
    out.append("\t\t\t\tBase,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tmainGroup = {id_main_group};")
    out.append("\t\t\tpackageReferences = (")
    out.append(f"\t\t\t\t{id_pkg_sodium} /* XCRemoteSwiftPackageReference \"swift-sodium\" */,")
    out.append(f"\t\t\t\t{id_pkg_firebase} /* XCRemoteSwiftPackageReference \"firebase-ios-sdk\" */,")
    out.append("\t\t\t);")
    out.append(f"\t\t\tproductRefGroup = {id_products_group} /* Products */;")
    out.append("\t\t\tprojectDirPath = \"\";")
    out.append("\t\t\tprojectRoot = \"\";")
    out.append("\t\t\ttargets = (")
    out.append(f"\t\t\t\t{id_core_target} /* PuxCore */,")
    out.append(f"\t\t\t\t{id_app_target} /* Pux */,")
    out.append(f"\t\t\t\t{id_nse_target} /* NotificationService */,")
    out.append(f"\t\t\t\t{id_test_target} /* PuxTests */,")
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")

    # PBXResourcesBuildPhase
    out.append("\n/* Begin PBXResourcesBuildPhase section */")
    out.append(f"\t\t{id_resources_app} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append(f"\t\t\t\t{id_assets_build} /* Assets.xcassets in Resources */,")
    out.append(f"\t\t\t\t{id_gservice_build} /* GoogleService-Info.plist in Resources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    out.append(f"\t\t{id_resources_nse} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    out.append(f"\t\t{id_resources_test} /* Resources */ = {{")
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")

    # PBXSourcesBuildPhase
    out.append("\n/* Begin PBXSourcesBuildPhase section */")
    # Core
    out.append(f"\t\t{id_sources_core} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for bf_id, name in core_build_files:
        out.append(f"\t\t\t\t{bf_id} /* {name} in Sources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    # App
    out.append(f"\t\t{id_sources_app} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for bf_id, name in app_build_files:
        out.append(f"\t\t\t\t{bf_id} /* {name} in Sources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    # NSE
    out.append(f"\t\t{id_sources_nse} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for bf_id, name in nse_build_files:
        out.append(f"\t\t\t\t{bf_id} /* {name} in Sources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")

    # Test
    out.append(f"\t\t{id_sources_test} /* Sources */ = {{")
    out.append("\t\t\tisa = PBXSourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for bf_id, name in test_build_files:
        out.append(f"\t\t\t\t{bf_id} /* {name} in Sources */,")
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")

    # PBXTargetDependency
    out.append("\n/* Begin PBXTargetDependency section */")
    out.append(f"\t\t{id_dep_core_app} /* PBXTargetDependency */ = {{")
    out.append("\t\t\tisa = PBXTargetDependency;")
    out.append(f"\t\t\ttarget = {id_core_target} /* PuxCore */;")
    out.append(f"\t\t\ttargetProxy = {id_proxy_core_app} /* PBXContainerItemProxy */;")
    out.append("\t\t};")

    out.append(f"\t\t{id_dep_core_nse} /* PBXTargetDependency */ = {{")
    out.append("\t\t\tisa = PBXTargetDependency;")
    out.append(f"\t\t\ttarget = {id_core_target} /* PuxCore */;")
    out.append(f"\t\t\ttargetProxy = {id_proxy_core_nse} /* PBXContainerItemProxy */;")
    out.append("\t\t};")

    out.append(f"\t\t{id_dep_core_test} /* PBXTargetDependency */ = {{")
    out.append("\t\t\tisa = PBXTargetDependency;")
    out.append(f"\t\t\ttarget = {id_core_target} /* PuxCore */;")
    out.append(f"\t\t\ttargetProxy = {id_proxy_core_test} /* PBXContainerItemProxy */;")
    out.append("\t\t};")

    out.append(f"\t\t{id_dep_nse_app} /* PBXTargetDependency */ = {{")
    out.append("\t\t\tisa = PBXTargetDependency;")
    out.append(f"\t\t\ttarget = {id_nse_target} /* NotificationService */;")
    out.append(f"\t\t\ttargetProxy = {id_proxy_nse_app} /* PBXContainerItemProxy */;")
    out.append("\t\t};")

    out.append(f"\t\t{id_dep_app_test} /* PBXTargetDependency */ = {{")
    out.append("\t\t\tisa = PBXTargetDependency;")
    out.append(f"\t\t\ttarget = {id_app_target} /* Pux */;")
    out.append(f"\t\t\ttargetProxy = {id_proxy_app_test} /* PBXContainerItemProxy */;")
    out.append("\t\t};")
    out.append("/* End PBXTargetDependency section */")

    # XCBuildConfiguration
    id_cfg_debug_proj = make_id("CFG_DEBUG_PROJ")
    id_cfg_release_proj = make_id("CFG_RELEASE_PROJ")

    id_cfg_debug_core = make_id("CFG_DEBUG_CORE")
    id_cfg_release_core = make_id("CFG_RELEASE_CORE")

    id_cfg_debug_app = make_id("CFG_DEBUG_APP")
    id_cfg_release_app = make_id("CFG_RELEASE_APP")

    id_cfg_debug_nse = make_id("CFG_DEBUG_NSE")
    id_cfg_release_nse = make_id("CFG_RELEASE_NSE")

    id_cfg_debug_test = make_id("CFG_DEBUG_TEST")
    id_cfg_release_test = make_id("CFG_RELEASE_TEST")

    out.append("\n/* Begin XCBuildConfiguration section */")
    # Project configs
    out.append(f"\t\t{id_cfg_debug_proj} /* Debug */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    out.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
    out.append("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
    out.append("\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";")
    out.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
    out.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
    out.append("\t\t\t\tCOPY_PHASE_STRIP = NO;")
    out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
    out.append("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
    out.append("\t\t\t\tENABLE_TESTABILITY = YES;")
    out.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
    out.append("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
    out.append("\t\t\t\t\t\"DEBUG=1\",")
    out.append("\t\t\t\t\t\"$(inherited)\",")
    out.append("\t\t\t\t);")
    out.append("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;")
    out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
    out.append("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
    out.append("\t\t\t\tSDKROOT = iphoneos;")
    out.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
    out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
    out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
    out.append("\t\t\t};")
    out.append("\t\t\tname = Debug;")
    out.append("\t\t};")

    out.append(f"\t\t{id_cfg_release_proj} /* Release */ = {{")
    out.append("\t\t\tisa = XCBuildConfiguration;")
    out.append("\t\t\tbuildSettings = {")
    out.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
    out.append("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
    out.append("\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";")
    out.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
    out.append("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
    out.append("\t\t\t\tCOPY_PHASE_STRIP = NO;")
    out.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
    out.append("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
    out.append("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
    out.append("\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;")
    out.append("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;")
    out.append("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
    out.append("\t\t\t\tSDKROOT = iphoneos;")
    out.append("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    out.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
    out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
    out.append("\t\t\t\tVALIDATE_PRODUCT = YES;")
    out.append("\t\t\t};")
    out.append("\t\t\tname = Release;")
    out.append("\t\t};")

    # Target Configurations
    marketing_ver = get_marketing_version()
    build_num = get_build_number()

    # Core configs
    for cfg_id, name in [(id_cfg_debug_core, "Debug"), (id_cfg_release_core, "Release")]:
        out.append(f"\t\t{cfg_id} /* {name} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.append("\t\t\t\tAPPLICATION_EXTENSION_API_ONLY = YES;")
        out.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        out.append(f"\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};")
        out.append("\t\t\t\tDEFINES_MODULE = YES;")
        out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
        out.append("\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;")
        out.append("\t\t\t\tDYLIB_CURRENT_VERSION = 1;")
        out.append("\t\t\t\tDYLIB_INSTALL_NAME_BASE = \"@rpath\";")
        out.append("\t\t\t\tINSTALL_PATH = \"$(LOCAL_LIBRARY_DIR)/Frameworks\";")
        out.append("\t\t\t\tMACH_O_TYPE = staticlib;")
        out.append(f"\t\t\t\tMARKETING_VERSION = {marketing_ver};")
        out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = xyz.vidur.pux.core;")
        out.append("\t\t\t\tPRODUCT_NAME = PuxCore;")
        out.append("\t\t\t\tPRODUCT_MODULE_NAME = PuxCore;")
        out.append("\t\t\t\tSKIP_INSTALL = YES;")
        out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
        out.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {name};")
        out.append("\t\t};")

    # App configs
    for cfg_id, name in [(id_cfg_debug_app, "Debug"), (id_cfg_release_app, "Release")]:
        out.append(f"\t\t{cfg_id} /* {name} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
        out.append("\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;")
        entitlements = "Sources/PuxApp/PuxRelease.entitlements" if name == "Release" else "Sources/PuxApp/Pux.entitlements"
        out.append(f"\t\t\t\tCODE_SIGN_ENTITLEMENTS = {entitlements};")
        out.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        out.append(f"\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};")
        out.append("\t\t\t\tFRAMEWORK_SEARCH_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"$(BUILT_PRODUCTS_DIR)\",")
        out.append("\t\t\t\t);")
        out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        out.append("\t\t\t\tINFOPLIST_FILE = Sources/PuxApp/Info.plist;")
        out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"@executable_path/Frameworks\",")
        out.append("\t\t\t\t);")
        out.append(f"\t\t\t\tMARKETING_VERSION = {marketing_ver};")
        out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = xyz.vidur.pux;")
        out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        out.append("\t\t\t\tSWIFT_INCLUDE_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"$(BUILT_PRODUCTS_DIR)\",")
        out.append("\t\t\t\t);")
        out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
        out.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {name};")
        out.append("\t\t};")

    # NSE configs
    for cfg_id, name in [(id_cfg_debug_nse, "Debug"), (id_cfg_release_nse, "Release")]:
        out.append(f"\t\t{cfg_id} /* {name} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Sources/NotificationService/NotificationService.entitlements;")
        out.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        out.append(f"\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};")
        out.append("\t\t\t\tFRAMEWORK_SEARCH_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"$(BUILT_PRODUCTS_DIR)\",")
        out.append("\t\t\t\t);")
        out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        out.append("\t\t\t\tINFOPLIST_FILE = Sources/NotificationService/Info.plist;")
        out.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"@executable_path/Frameworks\",")
        out.append("\t\t\t\t\t\"@executable_path/../../Frameworks\",")
        out.append("\t\t\t\t);")
        out.append(f"\t\t\t\tMARKETING_VERSION = {marketing_ver};")
        out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = xyz.vidur.pux.NotificationService;")
        out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        out.append("\t\t\t\tSKIP_INSTALL = YES;")
        out.append("\t\t\t\tSWIFT_INCLUDE_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"$(BUILT_PRODUCTS_DIR)\",")
        out.append("\t\t\t\t);")
        out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
        out.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {name};")
        out.append("\t\t};")

    # Test configs
    for cfg_id, name in [(id_cfg_debug_test, "Debug"), (id_cfg_release_test, "Release")]:
        out.append(f"\t\t{cfg_id} /* {name} */ = {{")
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.append("\t\t\t\tBUNDLE_LOADER = \"$(TEST_HOST)\";")
        out.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        out.append(f"\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};")
        out.append("\t\t\t\tFRAMEWORK_SEARCH_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"$(BUILT_PRODUCTS_DIR)\",")
        out.append("\t\t\t\t);")
        out.append("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
        out.append(f"\t\t\t\tMARKETING_VERSION = {marketing_ver};")
        out.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = xyz.vidur.pux.Tests;")
        out.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        out.append("\t\t\t\tSWIFT_INCLUDE_PATHS = (")
        out.append("\t\t\t\t\t\"$(inherited)\",")
        out.append("\t\t\t\t\t\"$(BUILT_PRODUCTS_DIR)\",")
        out.append("\t\t\t\t);")
        out.append("\t\t\t\tSWIFT_VERSION = 5.0;")
        out.append("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
        out.append("\t\t\t\tTEST_HOST = \"$(BUILT_PRODUCTS_DIR)/Pux.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Pux\";")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {name};")
        out.append("\t\t};")
    out.append("/* End XCBuildConfiguration section */")

    # XCConfigurationList
    out.append("\n/* Begin XCConfigurationList section */")
    out.append(f"\t\t{id_proj_configs} /* Build configuration list for PBXProject \"Pux\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{id_cfg_debug_proj} /* Debug */,")
    out.append(f"\t\t\t\t{id_cfg_release_proj} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")

    out.append(f"\t\t{id_configs_core} /* Build configuration list for PBXNativeTarget \"PuxCore\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{id_cfg_debug_core} /* Debug */,")
    out.append(f"\t\t\t\t{id_cfg_release_core} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")

    out.append(f"\t\t{id_configs_app} /* Build configuration list for PBXNativeTarget \"Pux\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{id_cfg_debug_app} /* Debug */,")
    out.append(f"\t\t\t\t{id_cfg_release_app} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")

    out.append(f"\t\t{id_configs_nse} /* Build configuration list for PBXNativeTarget \"NotificationService\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{id_cfg_debug_nse} /* Debug */,")
    out.append(f"\t\t\t\t{id_cfg_release_nse} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")

    out.append(f"\t\t{id_configs_test} /* Build configuration list for PBXNativeTarget \"PuxTests\" */ = {{")
    out.append("\t\t\tisa = XCConfigurationList;")
    out.append("\t\t\tbuildConfigurations = (")
    out.append(f"\t\t\t\t{id_cfg_debug_test} /* Debug */,")
    out.append(f"\t\t\t\t{id_cfg_release_test} /* Release */,")
    out.append("\t\t\t);")
    out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    out.append("\t\t\tdefaultConfigurationName = Release;")
    out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")

    # XCRemoteSwiftPackageReference
    out.append("\n/* Begin XCRemoteSwiftPackageReference section */")
    out.append(f"\t\t{id_pkg_sodium} /* XCRemoteSwiftPackageReference \"swift-sodium\" */ = {{")
    out.append("\t\t\tisa = XCRemoteSwiftPackageReference;")
    out.append("\t\t\trepositoryURL = \"https://github.com/jedisct1/swift-sodium.git\";")
    out.append("\t\t\trequirement = {")
    out.append("\t\t\t\tkind = upToNextMajorVersion;")
    out.append("\t\t\t\tminimumVersion = 0.11.0;")
    out.append("\t\t\t};")
    out.append("\t\t};")
    out.append(f"\t\t{id_pkg_firebase} /* XCRemoteSwiftPackageReference \"firebase-ios-sdk\" */ = {{")
    out.append("\t\t\tisa = XCRemoteSwiftPackageReference;")
    out.append("\t\t\trepositoryURL = \"https://github.com/firebase/firebase-ios-sdk.git\";")
    out.append("\t\t\trequirement = {")
    out.append("\t\t\t\tkind = exactVersion;")
    out.append("\t\t\t\tversion = 13.1.1;")
    out.append("\t\t\t};")
    out.append("\t\t};")
    out.append("/* End XCRemoteSwiftPackageReference section */")

    # XCSwiftPackageProductDependency
    out.append("\n/* Begin XCSwiftPackageProductDependency section */")
    out.append(f"\t\t{id_prod_sodium_core} /* Sodium */ = {{")
    out.append("\t\t\tisa = XCSwiftPackageProductDependency;")
    out.append(f"\t\t\tpackage = {id_pkg_sodium} /* XCRemoteSwiftPackageReference \"swift-sodium\" */;")
    out.append("\t\t\tproductName = Sodium;")
    out.append("\t\t};")

    out.append(f"\t\t{id_prod_sodium_app} /* Sodium */ = {{")
    out.append("\t\t\tisa = XCSwiftPackageProductDependency;")
    out.append(f"\t\t\tpackage = {id_pkg_sodium} /* XCRemoteSwiftPackageReference \"swift-sodium\" */;")
    out.append("\t\t\tproductName = Sodium;")
    out.append("\t\t};")

    out.append(f"\t\t{id_prod_firebase_app} /* FirebaseMessaging */ = {{")
    out.append("\t\t\tisa = XCSwiftPackageProductDependency;")
    out.append(f"\t\t\tpackage = {id_pkg_firebase} /* XCRemoteSwiftPackageReference \"firebase-ios-sdk\" */;")
    out.append("\t\t\tproductName = FirebaseMessaging;")
    out.append("\t\t};")

    out.append(f"\t\t{id_prod_sodium_nse} /* Sodium */ = {{")
    out.append("\t\t\tisa = XCSwiftPackageProductDependency;")
    out.append(f"\t\t\tpackage = {id_pkg_sodium} /* XCRemoteSwiftPackageReference \"swift-sodium\" */;")
    out.append("\t\t\tproductName = Sodium;")
    out.append("\t\t};")

    out.append(f"\t\t{id_prod_sodium_test} /* Sodium */ = {{")
    out.append("\t\t\tisa = XCSwiftPackageProductDependency;")
    out.append(f"\t\t\tpackage = {id_pkg_sodium} /* XCRemoteSwiftPackageReference \"swift-sodium\" */;")
    out.append("\t\t\tproductName = Sodium;")
    out.append("\t\t};")
    out.append("/* End XCSwiftPackageProductDependency section */")

    out.append("\t};")
    out.append(f"\trootObject = {id_proj} /* Project object */;")
    out.append("}")

    with open(PBX_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print(f"Generated {PBX_PATH}")

if __name__ == "__main__":
    generate()
