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
DYLIB_NAME="libharmony_uniffi.dylib"
FRAMEWORK_NAME="harmony_uniffiFFI"

# Absolute repo root: `xcodebuild -create-xcframework -debug-symbols` needs
# absolute dSYM paths, and it runs after we popd back here from $CRATE.
ROOT="$(pwd)"

mkdir -p Binaries "$OUT_SWIFT"

# Targets
rustup target add --toolchain "$RUSTUP_TOOLCHAIN" \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios \
  aarch64-apple-darwin \
  x86_64-apple-darwin >/dev/null

# Expose upstream render types for the FFI.
#
# harmony_uniffi constructs openai-harmony's RenderConversationConfig and
# RenderOptions directly, but upstream keeps them as `pub` structs inside a
# private `mod encoding` and never re-exports them at the crate root. So they
# can't be named by dependent crates even though the public render_conversation*
# methods take them as parameters. Re-export them from the submodule before
# building. Guarded (idempotent, and a no-op if upstream ever exposes them).
# Absolute path so the restore trap below resolves correctly regardless of the
# working directory at exit (the script pushd's into $CRATE before finishing).
HARMONY_LIB_RS="$(pwd)/rust/openai-harmony/src/lib.rs"
if [ -f "$HARMONY_LIB_RS" ] && ! grep -q "RenderConversationConfig" "$HARMONY_LIB_RS"; then
  # Restore the submodule file on exit so the build never leaves openai-harmony's
  # git working tree dirty (which can block branch switches or be committed by
  # accident). The re-export is only needed at build time and is re-applied on
  # every run, so it doesn't need to persist.
  HARMONY_LIB_RS_BACKUP="$(mktemp)"
  cp "$HARMONY_LIB_RS" "$HARMONY_LIB_RS_BACKUP"
  trap 'mv -f "$HARMONY_LIB_RS_BACKUP" "$HARMONY_LIB_RS"' EXIT
  cat >> "$HARMONY_LIB_RS" <<'EOF'

// Added at build time by scripts/build_uniffi.sh: expose the render config /
// options types that upstream leaves unreachable inside a private module.
pub use encoding::{RenderConversationConfig, RenderOptions};
EOF
fi

pushd "$CRATE" >/dev/null

# 1) Host build (macOS) for bindgen input
# (Using the default host target is fine; we'll build both mac slices later.)
rustup run "$RUSTUP_TOOLCHAIN" cargo build --release
HOST_LIB="target/release/${LIB_NAME}"

# 2) Generate Swift + headers (XCFramework-friendly)
rm -rf "$OUT_SWIFT" build/uniffi build/fat build/frameworks
mkdir -p \
  build/uniffi/Headers \
  build/fat/ios build/fat/ios-sim build/fat/macos \
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

# We ship the cdylib (dynamic library) as the framework binary - not the static
# archive - so the embedded framework is a genuine Mach-O image that code-signs,
# notarizes, and carries an LC_UUID we can match a dSYM to. The crate builds both
# (crate-type = ["staticlib", "cdylib"]); the static .a is used only as bindgen
# input above.
IOS_DYLIB="target/aarch64-apple-ios/release/${DYLIB_NAME}"

SIM_ARM_DYLIB="target/aarch64-apple-ios-sim/release/${DYLIB_NAME}"
SIM_X64_DYLIB="target/x86_64-apple-ios/release/${DYLIB_NAME}"

MAC_ARM_DYLIB="target/aarch64-apple-darwin/release/${DYLIB_NAME}"
MAC_X64_DYLIB="target/x86_64-apple-darwin/release/${DYLIB_NAME}"

IOS_FAT_DYLIB="build/fat/ios/${DYLIB_NAME}"
SIM_FAT_DYLIB="build/fat/ios-sim/${DYLIB_NAME}"
MAC_FAT_DYLIB="build/fat/macos/${DYLIB_NAME}"

# 4) Assemble per-destination dylibs. iOS device is single-arch; the simulator
# and macOS slices are universal (arm64 + x86_64).
cp "$IOS_DYLIB" "$IOS_FAT_DYLIB"
lipo -create "$SIM_ARM_DYLIB" "$SIM_X64_DYLIB" -output "$SIM_FAT_DYLIB"
lipo -create "$MAC_ARM_DYLIB" "$MAC_X64_DYLIB" -output "$MAC_FAT_DYLIB"

# 5) Assemble a dynamic framework bundle (+ dSYM) per slice.
#
# Framework-bundle slices keep module.modulemap inside the bundle
# (Modules/module.modulemap), so nothing is staged into the shared
# Build/Products/<config>/include/ - this is what avoids the "Multiple commands
# produce .../include/module.modulemap" collision with other static-lib
# XCFrameworks in the same build (e.g. chroma-swift's chroma_swiftFFI).
#
# The binary is the cdylib (a real Mach-O dynamic library), so the embedded
# framework code-signs and notarizes normally and has an LC_UUID we can match a
# dSYM to. Per slice we set the framework install name, extract a .dSYM with
# dsymutil, then strip debug info from the shipped binary (keeping the exported
# UniFFI symbols) so the slice stays small and the DWARF ships in the dSYM.
make_framework() {
  local dylib_path="$1"  # cdylib (dynamic library) for this slice
  local slice_dir="$2"   # output directory for this slice
  local min_os_key="$3"  # MinimumOSVersion (iOS) or LSMinimumSystemVersion (macOS)
  local min_os_ver="$4"
  local platform="$5"    # CFBundleSupportedPlatforms value: iPhoneOS / iPhoneSimulator / MacOSX

  local fw="$slice_dir/${FRAMEWORK_NAME}.framework"
  local dsym="$slice_dir/${FRAMEWORK_NAME}.framework.dSYM"
  rm -rf "$fw" "$dsym"

  # macOS frameworks require the versioned ("deep") bundle layout: the binary,
  # Headers, Modules and Resources/Info.plist live under Versions/A, with
  # top-level symlinks into Versions/Current (added after the files are written,
  # below). iOS and the simulator use the flat ("shallow") layout. Shipping the
  # shallow layout for macOS makes an embedding app fail to build with "contains
  # Info.plist, expected Versions/Current/Resources/Info.plist since the platform
  # does not use shallow bundles".
  local hdr_dir mod_dir plist_path bin_path install_name
  if [ "$platform" = "MacOSX" ]; then
    mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
    hdr_dir="$fw/Versions/A/Headers"
    mod_dir="$fw/Versions/A/Modules"
    plist_path="$fw/Versions/A/Resources/Info.plist"
    bin_path="$fw/Versions/A/${FRAMEWORK_NAME}"
    install_name="@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}"
  else
    mkdir -p "$fw/Headers" "$fw/Modules"
    hdr_dir="$fw/Headers"
    mod_dir="$fw/Modules"
    plist_path="$fw/Info.plist"
    bin_path="$fw/${FRAMEWORK_NAME}"
    install_name="@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
  fi

  cp "$dylib_path" "$bin_path"

  # Set the framework-relative install name so the embedding app loads it via
  # @rpath, extract a matching dSYM, then strip the shipped binary down to its
  # exported UniFFI globals (strip -x). install_name_tool and strip invalidate
  # the linker's ad-hoc code signature, and on Apple Silicon a dylib with a
  # broken/absent signature is killed on load (code-signature violation), so
  # re-sign ad-hoc afterwards. None of these steps change the Mach-O LC_UUID, so
  # the dSYM stays matched; Xcode re-signs the framework with the app's identity
  # when it embeds it.
  install_name_tool -id "$install_name" "$bin_path"
  dsymutil "$bin_path" -o "$dsym"
  strip -x "$bin_path"
  codesign --force --sign - "$bin_path"

  cp build/uniffi/Headers/* "$hdr_dir/"

  cat > "$mod_dir/module.modulemap" <<EOF
framework module ${FRAMEWORK_NAME} {
  umbrella header "${FRAMEWORK_NAME}.h"
  export *
}
EOF

  cat > "$plist_path" <<EOF
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
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${platform}</string>
	</array>
	<key>${min_os_key}</key>
	<string>${min_os_ver}</string>
</dict>
</plist>
EOF

  # macOS: create the version symlink (Current -> A) and the top-level symlinks
  # into it that make this a valid versioned framework bundle. iOS/simulator
  # slices are flat and need none of this.
  if [ "$platform" = "MacOSX" ]; then
    ln -s A                                    "$fw/Versions/Current"
    ln -s "Versions/Current/${FRAMEWORK_NAME}" "$fw/${FRAMEWORK_NAME}"
    ln -s Versions/Current/Headers             "$fw/Headers"
    ln -s Versions/Current/Modules             "$fw/Modules"
    ln -s Versions/Current/Resources           "$fw/Resources"
  fi
}

make_framework "$IOS_FAT_DYLIB" build/frameworks/ios     MinimumOSVersion       "$IOS_DEPLOYMENT_TARGET"   iPhoneOS
make_framework "$SIM_FAT_DYLIB" build/frameworks/ios-sim MinimumOSVersion       "$IOS_DEPLOYMENT_TARGET"   iPhoneSimulator
make_framework "$MAC_FAT_DYLIB" build/frameworks/macos   LSMinimumSystemVersion "$MACOS_DEPLOYMENT_TARGET" MacOSX

popd >/dev/null

# 6) Create XCFramework with iOS + iOS-sim + macOS framework slices, bundling
# each slice's dSYM so App Store Connect can symbolicate (and stops warning
# about missing symbols). -debug-symbols requires absolute paths.
rm -rf "$OUT_XC"
xcodebuild -create-xcframework \
  -framework "$CRATE/build/frameworks/ios/${FRAMEWORK_NAME}.framework" \
  -debug-symbols "$ROOT/$CRATE/build/frameworks/ios/${FRAMEWORK_NAME}.framework.dSYM" \
  -framework "$CRATE/build/frameworks/ios-sim/${FRAMEWORK_NAME}.framework" \
  -debug-symbols "$ROOT/$CRATE/build/frameworks/ios-sim/${FRAMEWORK_NAME}.framework.dSYM" \
  -framework "$CRATE/build/frameworks/macos/${FRAMEWORK_NAME}.framework" \
  -debug-symbols "$ROOT/$CRATE/build/frameworks/macos/${FRAMEWORK_NAME}.framework.dSYM" \
  -output "$OUT_XC"

echo "✅ Generated:"
echo "  - $OUT_SWIFT"
echo "  - $OUT_XC"
