# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(opencie LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "opencie")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# MSVC 14.4x+ escalates the <experimental/coroutine> deprecation (STL1011)
# into a hard compile error. C++/WinRT-based plugins (e.g.
# permission_handler_windows) still build as C++17 and pull that header in
# through cppwinrt, so silence the error until those plugins move to the
# C++20 <coroutine> header. Applied at directory scope, before the plugin
# subdirectories are added, so it reaches every plugin target.
add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Bundle opencie-pkcs11.dll for CIE native operations.
# The library is built separately via Meson from the opencie-pkcs11 project.
# At runtime, DynamicLibrary.open('opencie-pkcs11.dll') loads it from
# the same directory as the executable.
#
# Resolution order:
#   1. -DOPENCIE_PKCS11_LIB=<path>  (explicit cmake variable)
#   2. OPENCIE_PKCS11_LIB env var   (set by CI or shell before flutter build)
#   3. Default Meson builddir next to this project (developer convenience)
#
# Example (cmake):
#   cmake -DOPENCIE_PKCS11_LIB=C:/path/to/libopencie-pkcs11.dll ..
# Example (env var, picked up automatically by flutter build windows):
#   set OPENCIE_PKCS11_LIB=C:\path\to\libopencie-pkcs11.dll
#   flutter build windows --release

# Accept path from environment variable when not set on the cmake command line.
if(NOT OPENCIE_PKCS11_LIB AND DEFINED ENV{OPENCIE_PKCS11_LIB})
  set(OPENCIE_PKCS11_LIB "$ENV{OPENCIE_PKCS11_LIB}")
  message(STATUS "OPENCIE_PKCS11_LIB from environment: ${OPENCIE_PKCS11_LIB}")
endif()

# Fall back to the conventional Meson output location (cross-clang-mingw build).
if(NOT OPENCIE_PKCS11_LIB)
  set(_DEFAULT_DLL
    "${CMAKE_CURRENT_SOURCE_DIR}/../../opencie-pkcs11/builddir-clang-win/libopencie-pkcs11.dll")
  if(EXISTS "${_DEFAULT_DLL}")
    set(OPENCIE_PKCS11_LIB "${_DEFAULT_DLL}")
    message(STATUS "Found libopencie-pkcs11.dll at default location")
  else()
    message(WARNING
      "libopencie-pkcs11.dll not found.  "
      "Build opencie-pkcs11 first (meson setup builddir-clang-win "
      "--cross-file cross-clang-mingw.ini) or set OPENCIE_PKCS11_LIB.")
  endif()
endif()

if(OPENCIE_PKCS11_LIB)
  # The Meson build produces "libopencie-pkcs11.dll" but the Dart FFI code
  # calls DynamicLibrary.open('opencie-pkcs11.dll') (no "lib" prefix on Windows).
  # Rename during install so the app finds it at runtime.
  install(FILES "${OPENCIE_PKCS11_LIB}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    RENAME "opencie-pkcs11.dll"
    COMPONENT Runtime)
  message(STATUS "Bundling opencie-pkcs11.dll (from: ${OPENCIE_PKCS11_LIB})")
endif()

# Bundle runtime DLL dependencies alongside libopencie-pkcs11.dll.
# Required on Windows because the DLL is cross-compiled with MinGW/clang and
# dynamically links against vcpkg libraries and the MinGW C++ runtime.
#
# Set OPENCIE_PKCS11_DEPS_DIRS to a semicolon-separated list of directories
# containing the dependency DLLs, e.g.:
#   cmake -DOPENCIE_PKCS11_DEPS_DIRS="$VCPKG_ROOT/installed/x64-mingw-dynamic/bin;/usr/x86_64-w64-mingw32/bin" ..
# or via environment variable (picked up automatically by flutter build windows):
#   set OPENCIE_PKCS11_DEPS_DIRS=C:/path/to/deps
#   flutter build windows --release
#
# Typical deps (resolved by pefile analysis):
#   vcpkg/installed/x64-mingw-dynamic/bin/  →  libcrypto-3-x64.dll, libssl-3-x64.dll,
#     libcurl.dll, libpodofo.dll, libxml2.dll, libfreetype.dll, libpng16.dll,
#     libzlib1.dll, libjpeg-62.dll, libtiff.dll, libutf8proc.dll,
#     libbrotlidec.dll, libbrotlicommon.dll, libbz2.dll, libiconv-2.dll, liblzma.dll
#   /usr/x86_64-w64-mingw32/bin/  →  libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll
if(NOT OPENCIE_PKCS11_DEPS_DIRS AND DEFINED ENV{OPENCIE_PKCS11_DEPS_DIRS})
  set(OPENCIE_PKCS11_DEPS_DIRS "$ENV{OPENCIE_PKCS11_DEPS_DIRS}")
  message(STATUS "OPENCIE_PKCS11_DEPS_DIRS from environment: ${OPENCIE_PKCS11_DEPS_DIRS}")
endif()

if(OPENCIE_PKCS11_DEPS_DIRS)
  foreach(_depsdir ${OPENCIE_PKCS11_DEPS_DIRS})
    file(GLOB _deps "${_depsdir}/*.dll")
    if(_deps)
      install(FILES ${_deps}
        DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
        COMPONENT Runtime)
      list(LENGTH _deps _dep_count)
      message(STATUS "Bundling ${_dep_count} runtime DLLs from: ${_depsdir}")
    endif()
  endforeach()
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
