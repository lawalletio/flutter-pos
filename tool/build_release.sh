#!/usr/bin/env bash
# Build the signed release APKs for LaWallet POS.
#
# Emits into build/app/outputs/flutter-apk/:
#   lawallet-pos-v<version>.apk              universal — every ABI, for Zapstore / general use
#   lawallet-pos-v<version>-armeabi-v7a.apk  32-bit only — ZCS/Ciontek terminals, ~⅓ the size
#   lawallet-pos-v<version>-arm64-v8a.apk    64-bit only — modern phones
#
# Signing needs android/key.properties + android/app/upload-keystore.jks (both
# gitignored). Without them the Flutter build silently falls back to debug
# signing, which cannot update an existing release install — so we hard-fail.
#
# NOTE: --split-per-abi makes Flutter offset versionCode per ABI (armeabi-v7a
# +1000, arm64-v8a +2000). A split APK therefore outranks the universal one;
# moving a device from a split build back to universal is a downgrade and will
# be refused. Pick one channel per device and stay on it.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f android/key.properties ]]; then
    echo "error: android/key.properties missing — build would be debug-signed." >&2
    exit 1
fi

version="$(grep -m1 '^version:' pubspec.yaml | sed 's/^version: *//; s/+.*//')"
out="build/app/outputs/flutter-apk"
echo "==> building LaWallet POS v${version}"

flutter build apk --release
cp "$out/app-release.apk" "$out/lawallet-pos-v${version}.apk"

flutter build apk --release --split-per-abi
for abi in armeabi-v7a arm64-v8a; do
    cp "$out/app-${abi}-release.apk" "$out/lawallet-pos-v${version}-${abi}.apk"
done

echo
echo "==> artifacts"
for f in "$out/lawallet-pos-v${version}".apk "$out/lawallet-pos-v${version}"-*.apk; do
    printf '%8s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
    unzip -l "$f" | grep -oE 'lib/[a-z0-9_-]+/' | sort -u | sed 's/^/          /'
done
