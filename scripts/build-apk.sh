#!/usr/bin/env bash
# Build an installable APK for the zicro Android demo (issue #10).
#
# Pipeline: cross-compile examples/android.zig + native_app_glue.c into libzicro.so for
# each ABI with Zig (against the NDK's bionic libc), then package + sign an APK with the
# Android SDK build-tools (aapt2 → zipalign → apksigner, debug key).
#
# Env (defaults for this machine):
#   ANDROID_NDK_HOME=/opt/android-ndk   ANDROID_HOME=/opt/android-sdk
# Requires: zig, an SDK platform (android.jar) and build-tools, a JDK (keytool) for the
# debug key. Compile/link only — this script does not need a device.
set -euo pipefail
cd "$(dirname "$0")/.."

NDK="${ANDROID_NDK_HOME:-/opt/android-ndk}"
SDK="${ANDROID_HOME:-/opt/android-sdk}"
API="${ANDROID_API:-29}"
HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)"
SYSROOT="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
GLUE="$NDK/sources/android/native_app_glue"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
ANDROID_JAR="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)/android.jar"

OUT=zig-out/android
rm -rf "$OUT"; mkdir -p "$OUT/apk/lib"

echo "NDK=$NDK  SDK=$SDK  API=$API  build-tools=$(basename "$BT")"
echo "platform=$(dirname "$ANDROID_JAR" | xargs basename)"

# arm64 for real devices; x86_64 so the emulator works too.
declare -A ABIS=( [arm64-v8a]=aarch64-linux-android [x86_64]=x86_64-linux-android )
declare -A ARCHLIB=( [arm64-v8a]=aarch64-linux-android [x86_64]=x86_64-linux-android )

for ABI in "${!ABIS[@]}"; do
  TRIPLE="${ABIS[$ABI]}"
  LIBDIR="$SYSROOT/usr/lib/${ARCHLIB[$ABI]}/$API"
  LIBC="$OUT/ndk-libc-$ABI.txt"
  cat > "$LIBC" <<EOF
include_dir=$SYSROOT/usr/include
sys_include_dir=$SYSROOT/usr/include
crt_dir=$LIBDIR
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF
  mkdir -p "$OUT/apk/lib/$ABI"
  echo "── $ABI ($TRIPLE) ──"
  # C sources + their -I attach to the module they follow (-Mzicro); -L/-l are global
  # link flags. The glue's ANativeActivity_onCreate + our android_main link into one .so.
  zig build-lib -dynamic -OReleaseSmall \
    -target "$TRIPLE" -mcpu baseline \
    --libc "$LIBC" \
    -L "$LIBDIR" -landroid -llog -lc \
    --dep zicro -Mroot=examples/android.zig -I "$GLUE" -I vendor/stb \
    -cflags -O2 -fno-sanitize=undefined -isystem "$SYSROOT/usr/include/${ARCHLIB[$ABI]}" -- \
    "$GLUE/android_native_app_glue.c" vendor/stb/stb_truetype_impl.c \
    -Mzicro=src/android_root.zig \
    -femit-bin="$OUT/apk/lib/$ABI/libzicro.so"
done

# Package resources + manifest into a base APK, then add the native libs.
"$BT/aapt2" link \
  -I "$ANDROID_JAR" \
  --manifest android/AndroidManifest.xml \
  --min-sdk-version "$API" --target-sdk-version 34 \
  -o "$OUT/base.apk"

cp "$OUT/base.apk" "$OUT/zicro-unaligned.apk"
( cd "$OUT/apk" && zip -qr "../zicro-unaligned.apk" lib )

"$BT/zipalign" -f 4 "$OUT/zicro-unaligned.apk" "$OUT/zicro-aligned.apk"

# Debug keystore (generated once) + sign.
KS="$OUT/debug.keystore"
keytool -genkeypair -keystore "$KS" -alias androiddebugkey \
  -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1 || true
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/zicro.apk" "$OUT/zicro-aligned.apk"

echo
echo "✅ APK: $OUT/zicro.apk"
"$BT/apksigner" verify --print-certs "$OUT/zicro.apk" >/dev/null && echo "signature OK"
unzip -l "$OUT/zicro.apk" | grep -E "lib/|AndroidManifest" || true
