# Native contract — printer & NFC

Source of truth: the current `android-pos-wrapper` (WebView shell). In the native Flutter app
these WebView-injected JS bridges are replaced by **Flutter platform channels** to the same
underlying Android APIs / SDK. Vendored into this repo:

- `android/app/libs/SmartPos_1.9.4_R250117.jar` — the **ZCS SmartPos SDK** (`com.zcs.sdk.*`).
- `android/app/libs/zxing-core-3.3.0.jar` — QR support used by the SDK.
- `assets/images/lacrypta_logo.png` — receipt header logo.

> ⚠️ Correction vs. the initial exploration: the printer SDK is **ZCS SmartPos**
> (`com.zcs.sdk.DriverManager` / `Printer`), **not** a "Ciontek CTK PosApiHelper". Confirmed by
> reading `android-pos-wrapper/app/src/main/java/test/apidemo/service/PrintThread.java`.

## 1. Printer (ZCS SmartPos SDK)

Wrapper exposed `window.Android.print(jsonString)` → `PrintThread.print(JSONObject)`.

**SDK init**
```java
DriverManager mDriverManager = DriverManager.getInstance();
Printer mPrinter = mDriverManager.getPrinter();
```

**Status / paper-out**
```java
int printStatus = mPrinter.getPrinterStatus();
if (printStatus == SdkResult.SDK_PRN_STATUS_PAPEROUT) { // retry every 2s }
```

**Receipt layout (top → bottom)** — from `PrintThread.print`:
1. Header bitmap: `imageUrl` (downloaded) if present, else `assets/images/lacrypta_logo.png`
   via `mPrinter.setPrintAppendBitmap(bmp, ALIGN_CENTER)`.
2. `mPrinter.setPrintLine(10)` separator.
3. Right-aligned `BTC/USD {btcPrice}` + normal `Bloque: #{blockNumber}`.
4. Current date `yyyy-MM-dd HH:mm:ss`, then `--------------------------------`.
5. Items loop (textSize 18): `"{name} ({price}) x {qty}"`, one per line.
6. TOTAL block (textSize 40): `***** TOTAL *****`, `{currencyB} {totalB}`,
   center `{currency} {total}`, right `{totalSats} sats`.
7. Message (textSize 25, centered), default `"Welcome to efectivo digital"`.
8. Optional QR: `mPrinter.setPrintAppendQRCode(qrcode, 500, 500, ALIGN_CENTER)`.
9. `mPrinter.setPrintStart()`.

Formatting via `PrnStrFormat` (`setTextSize`, `setAli`, `setFont(PrnTextFont.MONOSPACE)`).

**Print JSON schema (input)**
```json
{
  "items": [{ "name": "string", "qty": 1, "price": 100.0 }],
  "totalSats": 1500000,
  "total": 5432.25,
  "currency": "ARS",
  "currencyB": "USD",
  "totalB": "3.72",
  "message": "Welcome to efectivo digital",
  "blockNumber": "872992",
  "btcPrice": "0.08 M",
  "qrcode": "optional string",
  "imageUrl": "optional header image URL"
}
```

### Flutter binding
`MethodChannel("pos/printer")` → Kotlin holds a single `Printer` instance and reimplements the
layout above. Method `print(Map order)` returns the ZCS status int. Bundle the vendored `.jar`s in
`android/app/build.gradle` (`implementation files('libs/SmartPos_1.9.4_R250117.jar')`, zxing).
Port `getCurrentDate()` and the paper-out retry.

## 2. NFC (Android NfcAdapter)

Wrapper used standard `NfcAdapter` foreground dispatch; on a discovered tag it decoded the **first
NDEF record** and called `window.injectedNFC.handleRead(text)` (errors → `handleError(reason)`).

**Read logic** (`NfcService.onNewIntent`)
- Trigger `NfcAdapter.ACTION_NDEF_DISCOVERED`.
- `Ndef.get(tag).getCachedNdefMessage().getRecords()[0]`.
- Require `TNF_WELL_KNOWN` + `RTD_TEXT`.
- Encoding: `(payload[0] & 0x80)==0 ? "UTF-8" : "UTF-16"`; skip language code
  `len = payload[0] & 0x3F`; text = `new String(payload, len+1, payload.length-len-1, enc)`.
- Payload is a LaWallet card URL, typically `lnurlw://…`.

`window.Android.isNFCAvailable()` returned hardcoded `true`; native version should query real
`NfcAdapter` capability.

### Flutter binding
`MethodChannel("pos/nfc")` + `EventChannel("pos/nfc/reads")`:
- `isAvailable() -> bool`
- `startRead()` — enable reader mode / foreground dispatch.
- `stopRead()` — disable + cancel pending read.
- read events stream the decoded NDEF text to Dart.

Evaluate the `nfc_manager` plugin first (uses reader mode); fall back to a custom channel if the
CS30Pro needs reader-mode tuning. Manifest: `NFC`, `CAMERA`, `INTERNET`, `WAKE_LOCK`;
portrait lock; keep-screen-on.

## 3. Parity notes / decisions to make during M0
- The vendored logo is `lacrypta_logo.png`; the wrapper's latest `PrintThread` actually referenced
  `R.mipmap.bitcoinpizzaday` (an event-specific header). Decide the default header for v1.
- Confirm exact `SdkResult` status constants for overheat/voltage on the target firmware.
- Confirm reader-mode vs. foreground-dispatch behaviour on the physical CS30Pro (needs device).
