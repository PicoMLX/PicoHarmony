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

# 2) Generate Swift + headers + modulemap (XCFramework-friendly)
rm -rf "$OUT_SWIFT" build/uniffi build/xc_headers build/fat
mkdir -p \
  build/uniffi/Headers build/uniffi/Modules \
  build/xc_headers/Headers build/xc_headers/Modules \
  build/fat/ios-sim build/fat/macos \
  "$OUT_SWIFT"

# Swift sources
rustup run "$RUSTUP_TOOLCHAIN" cargo run --release --bin uniffi-bindgen-swift -- \
  "$HOST_LIB" "$OUT_SWIFT" --swift-sources

# C header(s)
rustup run "$RUSTUP_TOOLCHAIN" cargo run --release --bin uniffi-bindgen-swift -- \
  "$HOST_LIB" build/uniffi/Headers --headers

# Modulemap for XCFramework packaging
rustup run "$RUSTUP_TOOLCHAIN" cargo run --release --bin uniffi-bindgen-swift -- \
  "$HOST_LIB" build/uniffi/Modules --xcframework --modulemap --modulemap-filename module.modulemap

cp -R build/uniffi/Headers/* build/xc_headers/Headers/
cp -R build/uniffi/Modules/* build/xc_headers/Modules/

# Ensure the modulemap matches the expected Swift import module name and is suitable for static libs
MODULEMAP_PATH="build/xc_headers/Modules/module.modulemap"
if [ -f "$MODULEMAP_PATH" ]; then
  cat > "$MODULEMAP_PATH" <<'EOF'
module harmony_uniffiFFI {
  header "harmony_uniffiFFI.h"
  export *
}
EOF
fi

# Flatten headers/modules into a single directory for xcodebuild
rm -rf build/xc_headers_flat
mkdir -p build/xc_headers_flat
cp build/xc_headers/Headers/* build/xc_headers_flat/
cp "$MODULEMAP_PATH" build/xc_headers_flat/

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

popd >/dev/null

# 5) Create XCFramework with iOS + iOS-sim + macOS
rm -rf "$OUT_XC"
xcodebuild -create-xcframework \
  -library "$CRATE/$IOS_LIB" -headers "$CRATE/build/xc_headers_flat" \
  -library "$CRATE/$SIM_FAT_LIB" -headers "$CRATE/build/xc_headers_flat" \
  -library "$CRATE/$MAC_FAT_LIB" -headers "$CRATE/build/xc_headers_flat" \
  -output "$OUT_XC"

echo "✅ Generated:"
echo "  - $OUT_SWIFT"
echo "  - $OUT_XC"
