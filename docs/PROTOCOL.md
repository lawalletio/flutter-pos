# Payment protocol — Lightning / Nostr (to reimplement in Dart)

Ported from the Next.js webapp (`mobile-pos`): `src/context/{Order,Nostr,LN}.tsx`,
`src/hooks/useVerifyLud21.ts`, `src/lib/utils.ts`, `src/types/{lnurl,order}.ts`.

## 0. Keys & relays

- **Keypair:** secp256k1 / **BIP-340 schnorr** (Nostr). Private key stored as hex
  (`nostrPrivateKey`, secure storage); public key derived. Sign with the equivalent of
  nostr-tools `finalizeEvent` (event id = sha256 of the serialized `[0,pubkey,created_at,kind,tags,content]`).
- **Relays** (`Nostr.tsx`):
  - default: `[ $NOSTR_RELAY, wss://relay.damus.io, wss://nostr-pub.wellorder.net ]`
  - suggested (settings): + `relay.nostr.band`, `relay.wellorder.net`, `relay.primal.net`, `relay.masize.com`
  - `cleanRelays()` → trim, prefix `wss://`, strip trailing `/`.
  - `REQUIRED_NOSTR_RELAY_COUNT = 2` (min relays to confirm a zap receipt).

## 1. Merchant setup (LUD-16 + NIP-05)

1. `fetchLNURL(address)` → `GET https://{domain}/.well-known/lnurlp/{user}` → `LNURLResponse`.
2. NIP-05 → `GET https://{domain}/.well-known/nostr.json?name={user}` → `nip05Pubkey`, relays.
3. Require `allowsNostr && nostrPubkey`. Persist as `destinationLUD06`. Derive:
   `zapEmitterPubKey = lud06.nostrPubkey`, `callbackUrl = lud06.callback`,
   `destinationPubKey = lud06.accountPubKey ?? lud06.lnurl`.

## 2. Order event (Nostr kind 1)

`generateOrderEvent(amountSats, products)`:
```
kind: 1, content: "", pubkey: <hex>, created_at: floor(now/1000)
tags:
  ["relays", ...relays]
  ["p", pubkey]
  ["t", "order"]
  ["nonce", uuid()]                              # MANDATORY — avoids id collision / invoice reuse
  ["description", json({ memo, amount })]
  ["products", json(products)]
```
Sign, cache as `IPayment{ isPaid:false, zapReceiptStatus:'pending' }`, then publish in background
to all relays (5s timeout); track `nostrPublishStatus` + `nostrRelayUrls`.

## 3. Invoice request (zap, kind 9734)

Build zap request:
```
kind: 9734, content: "", pubkey, created_at
tags: ["relays",...], ["amount", msats], ["lnurl","lnurl"], ["p", recipientPubkey],
      ["e", orderEventId, relays[0]]   # optional
```
Then `GET {callbackUrl}?amount={msats}&nostr={zapEventJSON}&lnurl={destinationPubKey}`.
Response `LNURLInvoiceResponseSuccess { pr, routes?, verify? }`:
- `currentInvoice = pr` (bolt11, shown as QR)
- `lud21VerifyUrl = verify`
- Race guard: an incrementing `invoiceRequestId` — discard stale responses; increment on `clear()`.

## 4. Dual payment detection

**Path A — NIP-57 zap receipt (kind 9735)**
```
filter: { kinds:[9735], authors:[zapEmitterPubKey], "#e":[orderId], since: now-30 }
```
On event: verify `pubkey == zapEmitterPubKey`; validate signature; decode `bolt11` tag
(`bolt11_decoder`) → millisats. Accumulate the **distinct relays** that delivered the receipt;
mark paid once seen on **≥ REQUIRED_NOSTR_RELAY_COUNT (2)** relays.

**Path B — LUD-21 verify poll**
`GET {verify}?t={ms}` (no-store) every ~2s → `{ status:'OK', settled, preimage, pr }`;
`settled==true` ⇒ paid. Reset the `settled` latch when the verify URL changes (new invoice) — use a
synchronous ref (mirrors `settledRef`, webapp commit 136d187), not just React state.

**Emergency check** (manual "Check event"): poll LUD-21 ~12×/6s **and** force-fetch the 9735 from the
relay set with a 5s timeout.

On paid: set `isPaid`, persist cache, auto-print (once, guard `isPrinted`), show confetti; if closing
a tab, remove it.

## 5. NFC card payment — LUD-03 withdraw ("tap to pay")

For paying with a physical LaWallet card instead of an external wallet scanning the QR:
1. NFC read → NDEF text `lnurlw://…` → replace scheme with `https://`.
2. `GET` it → LNURL-withdraw params `{ tag:"withdrawRequest", callback, k1, ... }`.
3. Pull payment: call the withdraw `callback` with `{ k1, pr }` (the invoice from §3),
   sending header `X-LaWallet-Param: federationId={FEDERATION_ID}` (see `requestCardEndpoint`).
4. Guard against duplicate posts (`processedInvoice` ref).

## 6. Admin card format (LaWallet federation)

`/admin`: read card info via NFC (init/assoc/activ/deleg state, `@lawallet.ar` identity, balance,
design, nonce). Format flow reads security + admin taps, then `POST https://api.lawallet.ar/card/reset/request`
with the captured security params; shows a QR for an admin to scan. (Confirm exact payload on a live card.)

## 7. Ancillary services

- Prices: `GET https://api.yadio.io/exrates/btc` → `.BTC.{ARS,USD}` / 1e8; SAT=1; 60s cache (`prices`).
- Block height: `GET https://mempool.space/api/v1/blocks/tip/height`.

## 8. Env / config
`LEDGER_PUBKEY`, `NOSTR_RELAY`, `FEDERATION_ID` (from webapp `.env`). Ship via `--dart-define` /
a `config` provider.

## Type reference
- `LNURLResponse { tag, callback, k1?, metadata?, minSendable?, maxSendable?, allowsNostr?, nostrPubkey?, accountPubKey?, lnurl?, nip05?, nip05Pubkey?, nip05Relays?, federationId? }`
- `LNURLInvoiceResponseSuccess { pr, routes?, verify? }`
- `LNURLVerifyResponse { status:'OK', settled, preimage, pr } | { status:'ERROR', reason }`
- `IPayment { id, items, amount, event, lud06, currentInvoice?, lud21VerifyUrl?, isPaid, isPrinted, createdAt, nostrPublishStatus, nostrRelayUrls, zapReceiptStatus, zapReceiptRelayUrls }`
- `ITab { id, name, items, amount, createdAt, updatedAt }`
- `Product { id, category_id, name, description, price:{ value, currency } }` (+`qty`)
