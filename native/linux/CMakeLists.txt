cmake_minimum_required(VERSION 3.16)
project(pux_linux C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(PkgConfig REQUIRED)

pkg_check_modules(GLIB REQUIRED glib-2.0 gio-2.0)
pkg_check_modules(GTK REQUIRED gtk+-3.0)
pkg_check_modules(SODIUM REQUIRED libsodium)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(_pux_static_sodium_default ON)
else()
    set(_pux_static_sodium_default OFF)
endif()
option(PUX_STATIC_SODIUM "Link libsodium statically" ${_pux_static_sodium_default})
if(PUX_STATIC_SODIUM)
    pkg_get_variable(PUX_SODIUM_LIBDIR libsodium libdir)
    find_file(PUX_SODIUM_STATIC_LIBRARY NAMES libsodium.a PATHS ${PUX_SODIUM_LIBDIR} ${SODIUM_LIBRARY_DIRS})
    if(NOT PUX_SODIUM_STATIC_LIBRARY)
        message(FATAL_ERROR "libsodium.a is required for portable Linux builds (install libsodium-dev on Debian/Ubuntu or libsodium-static on Fedora; use -DPUX_STATIC_SODIUM=OFF for a system-linked source build)")
    endif()
    set(PUX_SODIUM_LIBRARY ${PUX_SODIUM_STATIC_LIBRARY})
else()
    set(PUX_SODIUM_LIBRARY ${SODIUM_LIBRARIES})
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    pkg_check_modules(LIBSECRET REQUIRED libsecret-1)
else()
    pkg_check_modules(LIBSECRET libsecret-1)
endif()

find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)

# Pin the reviewed wslay snapshot so runtime dependencies do not vary by host.
set(WSLAY_SOURCES
    third_party/wslay/src/wslay_event.c
    third_party/wslay/src/wslay_frame.c
    third_party/wslay/src/wslay_net.c
    third_party/wslay/src/wslay_queue.c
)
set(WSLAY_INCLUDES
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/wslay/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/wslay/src
)
set_source_files_properties(${WSLAY_SOURCES} PROPERTIES COMPILE_DEFINITIONS HAVE_CONFIG_H)

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${WSLAY_INCLUDES}
    ${GLIB_INCLUDE_DIRS}
    ${GTK_INCLUDE_DIRS}
    ${SODIUM_INCLUDE_DIRS}
    ${CURL_INCLUDE_DIRS}
)

link_directories(
    ${GLIB_LIBRARY_DIRS}
    ${GTK_LIBRARY_DIRS}
    ${SODIUM_LIBRARY_DIRS}
    ${CURL_LIBRARY_DIRS}
)

if(LIBSECRET_FOUND)
    add_definitions(-DHAVE_LIBSECRET=1)
    include_directories(${LIBSECRET_INCLUDE_DIRS})
endif()

# Core static library containing all logic, crypto, networking, storage
add_library(pux_linux_core STATIC
    src/crypto/crypto.cpp
    src/storage/secret_store.cpp
    src/storage/secret_store_keyring_probe.cpp
    src/delivery/ws_keepalive.cpp
    src/storage/storage_coordinator.cpp
    src/storage/record_store.cpp
    src/api/api_client.cpp
    src/notifications/notification_service.cpp
    src/clipboard/sensitive_clipboard.cpp
    src/ui/removal_controller.cpp
    src/delivery/desktop_delivery_service.cpp
    src/delivery/websocket_client.cpp
    src/vendor/qrcodegen.cpp
    ${WSLAY_SOURCES}
)

target_link_libraries(pux_linux_core
    ${GLIB_LIBRARIES}
    ${GTK_LIBRARIES}
    ${PUX_SODIUM_LIBRARY}
    ${CURL_LIBRARIES}
    OpenSSL::SSL
    OpenSSL::Crypto
)

if(LIBSECRET_FOUND)
    target_link_libraries(pux_linux_core ${LIBSECRET_LIBRARIES})
endif()

# Main GTK executable
add_executable(pux
    src/ui/app_window.cpp
    src/main.cpp
)

target_link_libraries(pux
    pux_linux_core
    ${GTK_LIBRARIES}
    ${GLIB_LIBRARIES}
    ${PUX_SODIUM_LIBRARY}
    ${CURL_LIBRARIES}
    OpenSSL::SSL
    OpenSSL::Crypto
)

# Automated Unit Tests
add_executable(pux_linux_tests
    tests/test_main.cpp
    tests/test_crypto.cpp
    tests/test_record_store.cpp
    tests/test_notifications.cpp
    tests/test_api_client.cpp
    tests/test_delivery_service.cpp
    tests/test_websocket.cpp
    tests/test_secret_service.cpp
    tests/test_storage_coordinator.cpp
    tests/test_sensitive_clipboard.cpp
    tests/test_ui_gtk.cpp
    tests/test_app_window_views.cpp
    tests/test_websocket_alpn.cpp
    tests/test_ws_keepalive.cpp
    src/ui/app_window.cpp
)

target_link_libraries(pux_linux_tests
    pux_linux_core
    ${GLIB_LIBRARIES}
    ${GTK_LIBRARIES}
    ${PUX_SODIUM_LIBRARY}
    ${CURL_LIBRARIES}
    OpenSSL::SSL
    OpenSSL::Crypto
)

target_compile_definitions(pux_linux_tests PRIVATE PUX_LINUX_TESTING=1)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND LIBSECRET_FOUND)
    add_executable(pux_linux_keyring_locked_probe tests/keyring_locked_probe.cpp)
    target_link_libraries(pux_linux_keyring_locked_probe PRIVATE pux_linux_core ${GLIB_LIBRARIES})
    set_target_properties(
        pux_linux_keyring_locked_probe
        PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    )
endif()

enable_testing()
add_test(NAME pux_unit_tests COMMAND pux_linux_tests)

# Tarball layout, install guidance and linked-library checks.
add_test(NAME pux_packaging_checks COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/packaging/test_packaging.sh)
