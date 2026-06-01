cmake_minimum_required(VERSION 3.16)

project(TacticalRadioMumblePlugin
  VERSION 0.1.0
  DESCRIPTION "Roblox tactical radio bridge for Mumble"
  LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Must be set BEFORE add_subdirectory(external/mumble-plugin-cpp)
set(positional-audio ON CACHE BOOL "Enable positional audio callbacks" FORCE)
set(server-event-callbacks ON CACHE BOOL "Enable server event callbacks" FORCE)
set(audio-callbacks ON CACHE BOOL "Enable audio callbacks" FORCE)

add_subdirectory(
  external/mumble-plugin-cpp
  "${CMAKE_CURRENT_BINARY_DIR}/mumble-plugin-cpp"
)

target_compile_definitions(mumble_plugin_cpp_wrapper PUBLIC
  MUMBLE_PLUGIN_WRAPPER_USE_POSITIONAL_AUDIO
  MUMBLE_PLUGIN_WRAPPER_USE_SERVER_EVENT_CALLBACKS
  MUMBLE_PLUGIN_WRAPPER_USE_AUDIO_CALLBACKS
)

include(FetchContent)

FetchContent_Declare(
  cpp_httplib
  GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
  GIT_TAG master
)

FetchContent_Declare(
  nlohmann_json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
)

FetchContent_MakeAvailable(cpp_httplib nlohmann_json)

# Required so cpp-httplib can use https:// URLs.
# On Windows this is easiest via vcpkg:
#   vcpkg install openssl:x64-windows
find_package(OpenSSL REQUIRED)

add_library(tactical_radio_mumble_plugin SHARED
  src/TacticalRadioPlugin.cpp

  src/BridgeClient.cpp
  src/BridgeClient.hpp
  src/BridgeConfig.hpp
  src/SharedState.hpp

  src/PluginLogger.cpp
  src/PluginLogger.hpp

  src/MumbleIdentity.cpp
  src/MumbleIdentity.hpp

  src/PositionalCache.cpp
  src/PositionalCache.hpp

  src/PluginDiagnostics.cpp
  src/PluginDiagnostics.hpp

  src/RadioRouter.cpp
  src/RadioRouter.hpp

  src/AudioRadioEffects.cpp
  src/AudioRadioEffects.hpp
)

target_include_directories(tactical_radio_mumble_plugin PRIVATE
  src
)

target_compile_definitions(tactical_radio_mumble_plugin PRIVATE
  TACTICAL_RADIO_PLUGIN_VERSION="0.1.0"

  # Enables httplib::SSLClient / https:// support in cpp-httplib.
  CPPHTTPLIB_OPENSSL_SUPPORT
)

target_link_libraries(tactical_radio_mumble_plugin PRIVATE
  mumble_plugin_cpp_wrapper
  httplib::httplib
  nlohmann_json::nlohmann_json
  OpenSSL::SSL
  OpenSSL::Crypto
)

# Windows certificate / crypto APIs used by OpenSSL/cpp-httplib builds.
if (WIN32)
  target_link_libraries(tactical_radio_mumble_plugin PRIVATE
    Crypt32
    Ws2_32
  )
endif()

# Mumble wrapper exports can be stripped unless the wrapper static lib is force-linked.
# This fixes "Non-plugin found" / missing mumble_* exports.
if (MSVC)
  target_link_options(tactical_radio_mumble_plugin PRIVATE
    "/WHOLEARCHIVE:$<TARGET_FILE:mumble_plugin_cpp_wrapper>"
  )
endif()