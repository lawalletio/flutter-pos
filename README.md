# LaWallet POS (native Android — Flutter)

A from-scratch native rewrite of the LaWallet mobile POS. Replaces the Next.js PWA + WebView
wrapper (`mobile-pos` + `android-pos-wrapper`) with a single native Flutter app that reimplements
the Lightning/Nostr payment engine in Dart and talks to the Ciontek CS30Pro printer + NFC directly
via platform channels.

## Status: M0 (scaffold)

- ✅ Repo structure, `pubspec.yaml`, vendored ZCS SmartPos SDK + logo + menu assets
- ✅ Full reference docs (`docs/`)
- ⏳ `flutter create` platform boilerplate (needs Flutter SDK — not yet installed)
- ⏳ M0 risk spikes: printer channel, NFC channel, Dart Nostr/NIP-57 (need device + Flutter)

## Docs
- [`docs/FUNCTIONALITY.md`](docs/FUNCTIONALITY.md) — every screen & flow (parity spec)
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — Lightning/Nostr payment protocol to reimplement
- [`docs/NATIVE-CONTRACT.md`](docs/NATIVE-CONTRACT.md) — printer (ZCS SmartPos) + NFC contract
- [`docs/PARITY-CHECKLIST.md`](docs/PARITY-CHECKLIST.md) — release gate vs. the webapp

## Getting started (once Flutter is installed)

```bash
# from repo root — generates android/ios boilerplate around the existing lib/ + pubspec
flutter create . --org ar.lawallet --project-name lawallet_pos --platforms=android
flutter pub get
# wire the vendored SDK in android/app/build.gradle:
#   implementation files('libs/SmartPos_1.9.4_R250117.jar')
#   implementation files('libs/zxing-core-3.3.0.jar')
flutter analyze
flutter test
flutter run
```

## Releasing

```bash
tool/build_release.sh
```

Bump `version:` in `pubspec.yaml` first, then run the script. It produces three
signed APKs in `build/app/outputs/flutter-apk/`:

| Artifact | ABIs | Use |
|---|---|---|
| `lawallet-pos-v<v>.apk` | all | Zapstore + general distribution |
| `lawallet-pos-v<v>-armeabi-v7a.apk` | 32-bit | ZCS/Ciontek terminals — ~⅓ the size |
| `lawallet-pos-v<v>-arm64-v8a.apk` | 64-bit | modern phones |

Signing requires `android/key.properties` + `android/app/upload-keystore.jks`
(both gitignored); the script fails rather than silently debug-signing.

Note that `--split-per-abi` offsets `versionCode` per ABI (armeabi-v7a +1000,
arm64-v8a +2000), so a split APK outranks the universal one. Moving a device
from a split build back to universal is a downgrade and Android will refuse it
— pick one channel per device and stay on it.

## Architecture
Riverpod replaces the 6 React contexts. See the plan and `docs/`. Layered `lib/`:
`core` (theme/router/i18n/format) · `platform` (printer/nfc channels) · `data`
(nostr/lnurl/pricing/storage) · `domain` (order/tabs/card/config) · `features` (screens).

## Provenance
Payment protocol ported from `mobile-pos/src/context/{Order,Nostr,LN}.tsx` etc. Native contract from
`android-pos-wrapper` (`PrintThread.java`, `NfcService.java`, `WebInterface.java`). SDK jar + logo
vendored from that repo.
