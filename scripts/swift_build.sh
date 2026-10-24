#!/bin/bash
# Build with a coherent compiler/SDK pair.
#
# Apple's Command Line Tools can briefly get into a split-update state where
# `swift` is newer than the Swift interfaces in the selected macOS SDK. Swift
# then rejects the SDK before it even reads Package.swift. On that machine,
# use the installed macOS 15.4 SDK; it matches artbip's deployment target.
set -euo pipefail
cd "$(dirname "$0")/.."

build_args=()
scratch_path=${ARTBIP_SCRATCH_PATH:-${TMPDIR:-/tmp}/artbip-swift-build}
build_args+=(--scratch-path "$scratch_path")
default_sdk=$(xcrun --sdk macosx --show-sdk-path)
swift_version=$(swift --version 2>&1 | awk '
  { for (i = 1; i <= NF; i++) if ($i == "version" && $(i + 1) ~ /^[0-9]+\./) version = $(i + 1) }
  END { print version }
')
interface=$(find "$default_sdk/usr/lib/swift/Swift.swiftmodule" \
  -name '*-apple-macos.swiftinterface' -print -quit 2>/dev/null || true)
sdk_swift_version=
if [[ -n "$interface" ]]; then
  sdk_swift_version=$(awk '
    { for (i = 1; i <= NF; i++) if ($i == "version" && $(i + 1) ~ /^[0-9]+\./) { print $(i + 1); exit } }
  ' "$interface")
fi

if [[ -n "${ARTBIP_SDKROOT:-}" ]]; then
  export SDKROOT="$ARTBIP_SDKROOT"
  build_args+=(--sdk "$SDKROOT")
# Patch releases of the same Swift version can consume the SDK interfaces;
# falling back for a patch-only skew breaks the installed Swift Testing library.
elif [[ -n "$swift_version" && -n "$sdk_swift_version" \
     && "${swift_version%.*}" != "${sdk_swift_version%.*}" ]]; then
  fallback=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
  if [[ ! -d "$fallback" ]]; then
    echo "error: Swift $swift_version does not match the selected SDK's Swift $sdk_swift_version." >&2
    echo "       Update Command Line Tools, or set ARTBIP_SDKROOT to a compatible SDK." >&2
    exit 1
  fi
  export SDKROOT="$fallback"
  build_args+=(--sdk "$SDKROOT")
  echo "note: Swift $swift_version does not match SDK Swift $sdk_swift_version; using $SDKROOT" >&2
# The macOS 27 SDK implements SwiftUI's @State as a macro whose plugin ships
# only with Xcode. Command Line Tools alone cannot expand it, so fall back to
# the newest installed SDK whose SwiftUI does not need that plugin.
else
  needs_swiftui_macros() {
    grep -q 'module: "SwiftUIMacros", type: "StateMacro"' "$1/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface" 2>/dev/null
  }
  if needs_swiftui_macros "$default_sdk" \
     && [[ -z "$(find "$(xcode-select -p)" -name 'libSwiftUIMacros.dylib' -print -quit 2>/dev/null)" ]]; then
    fallback=
    for sdk in $(ls -d "$(dirname "$default_sdk")"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
      if ! needs_swiftui_macros "$sdk"; then fallback=$sdk; break; fi
    done
    if [[ -z "$fallback" ]]; then
      echo "error: the selected SDK's SwiftUI needs the SwiftUIMacros plugin, which ships only with Xcode." >&2
      echo "       Install Xcode, or set ARTBIP_SDKROOT to a macOS 26 SDK." >&2
      exit 1
    fi
    export SDKROOT="$fallback"
    build_args+=(--sdk "$SDKROOT")
    echo "note: $(basename "$default_sdk") needs Xcode's SwiftUIMacros plugin; using $SDKROOT" >&2
  fi
fi

# Inside an outer seatbelt sandbox (signalled by CODEX_SANDBOX), SwiftPM's
# nested sandbox is unavailable. Its normal sandbox remains enabled everywhere
# else.
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
  export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-module-cache}"
  build_args+=(--disable-sandbox --cache-path "$PWD/.build")
fi

swift_action=build
if [[ "${1:-}" == "--test" ]]; then
  swift_action=test
  build_args+=(--disable-xctest)
  # CLT ships Swift Testing outside the SDK's normal framework search path.
  testing_frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
  if [[ -d "$testing_frameworks/Testing.framework" ]]; then
    build_args+=(-Xswiftc -F -Xswiftc "$testing_frameworks"
                 -Xlinker -F -Xlinker "$testing_frameworks"
                 -Xlinker -rpath -Xlinker "$testing_frameworks"
                 -Xlinker -rpath -Xlinker "$testing_frameworks/../usr/lib")
    # CLT keeps Testing's macros in a nested directory that is not always
    # discovered by SwiftPM's incremental build plan. Declare the installed
    # plugin alongside the explicit Testing framework so fresh tests compile.
    testing_plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$testing_plugin" ]]; then
      build_args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
    fi
  fi
  shift
fi
exec swift "$swift_action" "${build_args[@]}" --disable-automatic-resolution "$@"
