# Releasing

One version ships to three channels: GitHub Releases and Zapstore (Android APKs),
and the Apple App Store (iOS).

## 1. Bump the version

Edit `version:` in `pubspec.yaml`, e.g. `0.2.7+14`.

- The part before `+` is the user-facing version: Android `versionName`, iOS
  `CFBundleShortVersionString`.
- The part after `+` is the build number: Android `versionCode`, iOS
  `CFBundleVersion`. It must go up on every release. App Store Connect refuses a
  build number it has already seen for that version.

Commit as `chore(release): v<version>`, merge to `main`, and release from `main`.

## 2. Android

### Build

```bash
tool/build_release.sh
```

Signing needs `android/key.properties` and `android/app/upload-keystore.jks`.
Both are gitignored, and the script fails without them rather than debug-signing.
It writes three APKs to `build/app/outputs/flutter-apk/`:

| Artifact | ABIs | Use |
|---|---|---|
| `lawallet-pos-v<v>.apk` | all | Zapstore and general distribution |
| `lawallet-pos-v<v>-armeabi-v7a.apk` | 32-bit | ZCS/Ciontek terminals, about ⅓ the size |
| `lawallet-pos-v<v>-arm64-v8a.apk` | 64-bit | modern phones |

`--split-per-abi` offsets `versionCode` per ABI (armeabi-v7a +1000, arm64-v8a
+2000), so a split APK outranks the universal one. Moving a device from a split
build back to universal is a downgrade, and Android refuses it. Pick one channel
per device and stay on it.

### GitHub release

```bash
v=$(grep -m1 '^version:' pubspec.yaml | sed 's/^version: *//; s/+.*//')
git tag "v$v" && git push origin "v$v"
gh release create "v$v" build/app/outputs/flutter-apk/lawallet-pos-v$v*.apk \
  --title "v$v — <headline>" --notes-file <notes.md>
```

Release notes are in Spanish and written for the merchant: what changed on
screen, not how it was built.

### Zapstore

Zapstore reads `zapstore.yaml`, which points at this repo's GitHub releases.
Publish after the GitHub release exists:

```bash
SIGN_WITH=<nsec | bunker:// | browser> zsp publish zapstore.yaml
```

Sign with the key behind the `pubkey` in `zapstore.yaml`.

## 3. iOS (App Store)

| | |
|---|---|
| App Store Connect app | LaWallet POS, Apple ID `6824332449` |
| Bundle ID | `ar.lawallet.pos` |
| Team | `JL86VWP8H7` |
| Primary language | Español (México) |

The app is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), portrait-only, and needs
iOS 15.5+. The printer and NFC channels have no iOS side. They report "not
available", and the screens that need them degrade gracefully.

### One-time setup on a new Mac

Signing is manual for Release and Profile builds (Debug stays Automatic). The
Mac building the IPA needs:

1. **The Apple Distribution identity in the login keychain.** Import the
   maintainer's `ios_distribution.p12`; its password sits next to it in
   `ios_distribution.p12.password`:
   ```bash
   security import ios_distribution.p12 -k ~/Library/Keychains/login.keychain-db \
     -P "$(cat ios_distribution.p12.password)" -T /usr/bin/codesign
   ```
   If `security find-identity -v -p codesigning` doesn't list it as valid,
   install Apple's intermediate certificate:
   `curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security import AppleWWDRCAG3.cer`.
2. **The `LaWallet POS App Store` provisioning profile.** Copy it into both
   profile folders, named by its UUID:
   ```bash
   uuid=$(security cms -D -i LaWallet_POS_App_Store.mobileprovision | plutil -extract UUID raw -)
   for d in ~/Library/MobileDevice/Provisioning\ Profiles ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles; do
     mkdir -p "$d" && cp LaWallet_POS_App_Store.mobileprovision "$d/$uuid.mobileprovision"
   done
   ```
3. **An App Store Connect API key** (`AuthKey_<KEY_ID>.p8`), its key ID and the
   team's issuer ID. Both IDs are shown at App Store Connect › Users and Access ›
   Integrations › App Store Connect API.

The certificate and profile both expire on **2027-10-18**. To renew:
1. Make a new key and CSR with
   `openssl req -new -newkey rsa:2048 -nodes -keyout ios_distribution.key -out ios_distribution.csr -subj "/CN=Agustin Kassis/C=AR"`.
2. Upload the CSR to developer.apple.com › Certificates › **Apple Distribution**.
3. Regenerate the **App Store Connect** profile for `ar.lawallet.pos`, keeping
   the name `LaWallet POS App Store`, because the Xcode project refers to it by
   that name.
4. Rebuild the `.p12` with `openssl pkcs12 -export -legacy`.

Keep all of these files out of the repo.

### Automated: GitHub Actions

`.github/workflows/ios-release.yml` runs when a GitHub release is published, so
the `gh release create` from the Android step also ships iOS. It does five
things:

1. Checks that the release tag matches `pubspec.yaml` (`v0.2.7` ↔ `0.2.7+14`).
2. Imports the signing certificate and profile into a throwaway keychain.
3. Runs `flutter build ipa` on `macos-26`.
4. Turns the release body into plain-text **What's New** (es-MX, 4000 characters max).
5. Runs `fastlane deliver`. That uploads the IPA, creates the App Store version
   if it doesn't exist, waits for processing, attaches the build and submits it
   for review with automatic release on approval.

The listing (description, screenshots, URLs, privacy answers) isn't touched.
Change it in the website.

To re-run it, use **Actions › iOS release › Run workflow**. It has three inputs:
- `submit`: untick it to upload without submitting for review;
- `release_notes`: optional What's New text;
- `dry_run`: only builds the signed IPA and checks the API key. Nothing is
  uploaded. Use it after changing secrets or renewing the certificate.

Before uploading, the workflow compares the build number with the latest one
App Store Connect has, and fails early if it isn't higher.

Repository secrets (Settings › Secrets and variables › Actions):

| Secret | Value |
|---|---|
| `IOS_DIST_P12_BASE64` | `base64 -i ios_distribution.p12` |
| `IOS_DIST_P12_PASSWORD` | contents of `ios_distribution.p12.password` |
| `IOS_PROFILE_BASE64` | `base64 -i LaWallet_POS_App_Store.mobileprovision` |
| `ASC_KEY_ID` | the API key's ID |
| `ASC_ISSUER_ID` | the team's issuer ID |
| `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_<KEY_ID>.p8` |

The API key needs the **App Manager** (or Admin) role. A Developer key can
upload, but the submit step fails with `FORBIDDEN_ERROR`. Create the key at App
Store Connect › Users and Access › Integrations › App Store Connect API. You can
only download it once.

When the certificate or profile is renewed (next: 2027-10-18), update the three
`IOS_*` secrets too.

The workflow can't submit if one of these is true:
- a license agreement is waiting to be accepted;
- a previous version is still in review. Remove it from review, or wait for it
  to finish;
- the build number was already uploaded;
- a previous version was rejected and its submission is still open.

The job fails with Apple's message in each case.

#### After a rejection

When App Review rejects a version, or asks for more information (Guideline
2.1), its submission stays open as **Unresolved issues** until you act on it:

1. Answer Apple under **App Review › the submission › Reply to App Review**.
   Attach files there, such as a screen recording. Also copy the answers into the
   version's **App Review Information › Notes**, so later reviews have them.
2. If the fix needs a new build, bump the version and publish the GitHub release
   as usual. The workflow renames the rejected version to the new number,
   uploads the build and attaches it. It then fails at the submit step with
   `A review submission is already in progress`. That's expected.
3. In App Store Connect, open the version page and click **Update Review**.
   The item in the submission changes to *Ready for Review*. Then open the
   submission and click **Resubmit to App Review**. Until you click Update
   Review, the Resubmit button stays disabled. This keeps Apple's message
   thread with your reply. Canceling the submission and creating a new one
   loses it.

If the answer alone resolves it and no new build is needed, skip step 2.

### Build and upload by hand

```bash
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist

API_PRIVATE_KEYS_DIR=<folder with AuthKey_<KEY_ID>.p8> \
xcrun altool --upload-app --type ios -f "build/ios/ipa/LaWallet POS.ipa" \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

`UPLOAD SUCCEEDED` means Apple received the build. Processing takes 5–15
minutes, and the build then appears under the app's TestFlight tab. Testers can
install it from there before review.

A key with the **Developer** role can upload, but it can't attach builds, edit
metadata or submit. Do those steps in the App Store Connect website, or use a
key with the App Manager or Admin role.

### Submit for review (App Store Connect website)

1. **Apps › LaWallet POS › Distribution**. Create the new iOS version with
   **+ (Add platform / version)**, using the same version string as `pubspec.yaml`.
2. Fill in **What's New** (Spanish). The description, keywords, screenshots and
   URLs carry over from the previous version. Change them only if the UI changed.
3. Under **Build**, click **+** and pick the uploaded build. The encryption
   question is already answered: `Info.plist` sets
   `ITSAppUsesNonExemptEncryption = false`.
4. Check **App Review Information**: no sign-in required, contact
   info@lacrypta.ar, and the test notes (configure `barra@lacrypta.ar`, charge an
   amount, a QR invoice appears).
5. **Save › Add for Review › Submit for Review**. Review usually takes 24–48 h.
   The version is set to release automatically once approved. Switch to manual
   release on the version page if a launch has to be timed.

If submitting is blocked, check the banners on **Apps**. Apple periodically
updates the Developer Program License Agreement, and the account holder has to
accept it at developer.apple.com/account before any submission.

### Screenshots

The store needs 6.3″ iPhone screenshots (1206 × 2622). Take them on the
**iPhone 17 Pro Max** simulator, which captures 1320 × 2868, and scale them down:

```bash
flutter build ios --simulator && xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted ar.lawallet.pos
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl io booted screenshot shot.png
sips -z 2622 1206 -s format jpeg shot.png --out shot-6.3.jpg
```

Use the `barra@lacrypta.ar` merchant: the home screen, a cart, and the invoice QR.
Keep the merchant's joke product names out of frame.

### Listing answers already on file

These were set for 0.2.6. Revisit them if the app changes what it does.

- **Category:** Finance (primary), Business (secondary).
- **Price:** free, in all 175 regions.
- **Age rating:** 4+ (every questionnaire answer is "none").
- **App Privacy:** no data collected. The privacy policy is
  https://lawallet.io/legal#privacy.
- **Content rights:** no third-party content.
- **EU Digital Services Act trader status:** not set yet. Set it under App
  Information › App Store Regulations, or the app is taken off sale in the EU.
