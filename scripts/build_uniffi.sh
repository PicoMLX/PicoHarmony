#!/usr/bin/env bash
set -euo pipefail

# We keep Homebrew-installed tools, but for iOS/macOS cross targets we must use a rustup-managed toolchain
# because the per-target std/core libraries are distributed via rustup components.
RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}"

# Explicit deployment targets to avoid producing object files that target the
# host macOS version (e.g. 26.x) when consumers link against macOS 15.0.
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-15.0}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
export IPHONESIMULATOR_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"

# Ensure the toolchain exists (no-op if already installed)
rustup toolchain install "$RUSTUP_TOOLCHAIN" >/dev/null 2>&1 || true

CRATE="rust/harmony_uniffi"
OUT_XC="Binaries/harmony_uniffiFFI.xcframework"
OUT_SWIFT="Sources/PicoHarmonyGenerated"

LIB_NAME="libharmony_uniffi.a"
FRAMEWORK_NAME="harmony_uniffiFFI"

mkdir -p Binaries "$OUT_SWIFT"

# Targets
rustup target add --toolchain "$RUSTUP_TOOLCHAIN" \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios \
  aarch64-apple-darwin \
  x86_64-apple-darwin >/dev/null

pushd "$CRATE" >/dev/null

# 1) Host build (macOS) for bindgen input
# (Using the default host target is fine; we'll build both mac slices later.)
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release
HOST_LIB="target/release/${LIB_NAME}"

# 2) Generate Swift + headers (XCFramework-friendly)
rm -rf "$OUT_SWIFT" build/uniffi build/fat build/frameworks
mkdir -p \
  build/uniffi/Headers \
  build/fat/ios-sim build/fat/macos \
  "$OUT_SWIFT"

# Swift sources
rustup run "$RUSTUP_TOOLCHAIN" cargo run --release --bin uniffi-bindgen-swift -- \
  "$HOST_LIB" "$OUT_SWIFT" --swift-sources

# C header(s)
rustup run "$RUSTUP_TOOLCHAIN" cargo run --release --bin uniffi-bindgen-swift -- \
  "$HOST_LIB" build/uniffi/Headers --headers

# 3) Build libs for each target
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release --target aarch64-apple-ios
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release --target aarch64-apple-ios-sim
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release --target x86_64-apple-ios
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release --target aarch64-apple-darwin
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release --target x86_64-apple-darwin

IOS_LIB="target/aarch64-apple-ios/release/${LIB_NAME}"

SIM_ARM_LIB="target/aarch64-apple-ios-sim/release/${LIB_NAME}"
SIM_X64_LIB="target/x86_64-apple-ios/release/${LIB_NAME}"

MAC_ARM_LIB="target/aarch64-apple-darwin/release/${LIB_NAME}"
MAC_X64_LIB="target/x86_64-apple-darwin/release/${LIB_NAME}"

SIM_FAT_LIB="build/fat/ios-sim/${LIB_NAME}"
MAC_FAT_LIB="build/fat/macos/${LIB_NAME}"

# 4) Create fat libs for simulator + macOS
lipo -create "$SIM_ARM_LIB" "$SIM_X64_LIB" -output "$SIM_FAT_LIB"
lipo -create "$MAC_ARM_LIB" "$MAC_X64_LIB" -output "$MAC_FAT_LIB"

# 5) Assemble a static framework bundle per slice.
#
# Framework-bundle slices keep module.modulemap inside the bundle
# (Modules/module.modulemap). Bare -library/-headers slices instead ship a
# root Headers/module.modulemap that Xcode stages into the shared
# Build/Products/<config>/include/, which collides with any other static-lib
# XCFramework in the same build (e.g. chroma-swift's chroma_swiftFFI) and
# fails with "Multiple commands produce .../include/module.modulemap".
# The framework binary is still the static archive, so linking semantics are
# unchanged and nothing is embedded at runtime.
make_framework() {
  local lib_path="$1"   # static archive for this slice
  local slice_dir="$2"  # output directory for this slice
  local min_os_key="$3" # MinimumOSVersion (iOS) or LSMinimumSystemVersion (macOS)
  local min_os_ver="$4"

  local fw="$slice_dir/${FRAMEWORK_NAME}.framework"
  rm -rf "$fw"
  mkdir -p "$fw/Headers" "$fw/Modules"

  cp "$lib_path" "$fw/${FRAMEWORK_NAME}"
  cp build/uniffi/Headers/* "$fw/Headers/"

  cat > "$fw/Modules/module.modulemap" <<EOF
framework module ${FRAMEWORK_NAME} {
  umbrella header "${FRAMEWORK_NAME}.h"
  export *
}
EOF

  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>com.picomlx.harmony-uniffi-ffi</string>
	<key>CFBundleName</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>${min_os_key}</key>
	<string>${min_os_ver}</string>
</dict>
</plist>
EOF
}

make_framework "$IOS_LIB"     build/frameworks/ios     MinimumOSVersion       "$IOS_DEPLOYMENT_TARGET"
make_framework "$SIM_FAT_LIB" build/frameworks/ios-sim MinimumOSVersion       "$IOS_DEPLOYMENT_TARGET"
make_framework "$MAC_FAT_LIB" build/frameworks/macos   LSMinimumSystemVersion "$MACOS_DEPLOYMENT_TARGET"

popd >/dev/null

# 6) Create XCFramework with iOS + iOS-sim + macOS framework slices
rm -rf "$OUT_XC"
xcodebuild -create-xcframework \
  -framework "$CRATE/build/frameworks/ios/${FRAMEWORK_NAME}.framework" \
  -framework "$CRATE/build/frameworks/ios-sim/${FRAMEWORK_NAME}.framework" \
  -framework "$CRATE/build/frameworks/macos/${FRAMEWORK_NAME}.framework" \
  -output "$OUT_XC"

echo "✅ Generated:"
echo "  - $OUT_SWIFT"
echo "  - $OUT_XC"
