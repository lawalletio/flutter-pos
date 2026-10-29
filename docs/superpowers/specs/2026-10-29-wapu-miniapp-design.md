# Wapu mini-app design

Date: 2026-10-29
Status: approved. The user approved the flow and waived further spec review.

## Goal

A merchant uses the POS to sell bitcoin to a walk-in customer:

1. The customer gives a lightning address.
2. The POS shows a WapuPay bank alias, a CVU and an exact ARS amount.
3. The customer pays that amount by bank transfer from their own bank.
4. WapuPay sends the sats to the customer's lightning address.

The mini-app drives the WapuPay ramp-on (`type=crypto_purchase`) with the merchant's API key. It covers only the ARS to Lightning path of the wapu-app "swaps" screen, and it behaves the way that path does in wapu-app today.

## Decisions

1. **Who sells to whom.** The POS sells BTC to walk-in customers. Orders, limits and history belong to the merchant's WapuPay account (the API key owner). The customer's lightning address receives the sats.
2. **Payment.** The customer pays only by bank transfer to the alias or CVU the POS shows. There is no cash payment.
3. **Destination first.** The sale starts with the customer's lightning address, then the amount.
4. **Credentials per POS user.** The API key and backend URL are stored per POS user, meaning per `merchantAddress`.
   - A different POS user is asked for a key.
   - Coming back to a user who already saved a key does not ask again.
5. **Config.** A gear button in the Wapu app bar opens the config.
   - When a mini-app PIN is set, the gear first asks for it (`confirmMiniappPin`). Rueda's gear does not do this.
   - Like Rueda's gear, it is hidden while the till is locked into the mini-app.
   - The config holds:
   - the API key;
   - the backend URL, an advanced field that defaults to `https://be-prod.wapu.app`;
   - a **Beta features** switch.
6. **Beta features.** The switch is the WapuPay account's `beta_version`, the flag that enables buying in wapu-app.
   - It is on by default. Saving a key sets the account's flag to match the switch, on or off.
   - If the merchant turns it off, the backend rejects new orders with 403 and the mini-app says why.
7. **New sale at any time.** "Nueva venta" (new sale) is reachable at any time except while an order is being created or funded, and returns to the destination step. The order in progress is abandoned and expires on its own, because the backend has no cancel. If the order already shows bank details, the POS asks for confirmation first.
8. **History.** A "Historial" (history) button lists the account's ARS to Lightning orders, with in-progress orders first. Tapping one reopens its status and resumes polling.
9. **Name.** The mini-app is called "Wapu", with the subtitle "Bitcoin sin KYC".
10. **Platform.** Only the Android APK is in scope.

## Out of scope

- **Cancelling an order.** survivors has no cancel route for ramp-on orders. Abandoned orders expire.
- **BOLT11 invoices as the destination.** The backend accepts only LUD-16 lightning addresses. Accepting invoices needs a survivors change; it is noted as a later phase.
- **Backend changes.** The open-order cap stays a global setting. Ops raises `ramp_on_user_open_cap` with the Telegram `/settings` command.
- **Ticket printing.**
- **iOS.**

## Backend contract

The contract comes from survivors `develop` at 6c0f1dbe. All paths are relative to the backend URL.

**Request rules:**

- Auth is the `X-API-Key: <key>` header only. Sending `Authorization` and `X-API-Key` together returns 400.
- Requests with a body send `Content-Type: application/json`.
- Amounts are JSON integers: ARS cents, or sats.
- Error bodies look like `{"error": "<message>"}`.
- Timestamps are UTC, formatted `YYYY-MM-DDTHH:MM:SSZ`.

| Call | Request | Result |
|---|---|---|
| Quote | `GET /transactions/direct-fiat/quote?type=crypto_purchase&payout_currency=SAT&payout_network=LIGHTNING` plus exactly one of `amount_ars_cents` or `amount_out` (digits only) | 200 with a quote |
| Create | `POST /transactions/direct-fiat/tentatives` with `{type, payout_currency: "SAT", payout_network: "LIGHTNING", payout_address, amount_ars_cents \| amount_out}` | 201 with an order. Not idempotent. |
| Funding | `POST /transactions/direct-fiat/tentatives/{id}/funding` with `{}` | 201 with the order, now including `alias` and `cvu`. A replay returns the same order. |
| Detail | `GET /transactions/direct-fiat/tentatives/{id}` | 200 with the order, or 404 if it is not the caller's order |
| List | `GET /transactions/direct-fiat/tentatives` | 200 with `{"tentatives": [order, ...]}` |
| Read settings | `GET /users/user-settings` | 200 with `{language, beta_version, favorite_currency}` |
| Write settings | `PATCH /users/user-settings` with `{"beta_version": bool}` | 200 |

**Quote fields:**

- amounts: `amount_ars_cents`, `amount_out` (sats), `amount_out_unit` (`"sats"`), `network_fee_out`;
- USDT cents: `total_amount_usdt`, `fee_amount_usdt`, `funding_amount_usdt`;
- limits: `min_amount_ars_cents`, `expiration_minutes`;
- availability: `liquidity_ok`.

**Order fields:**

- identity and status: `tentative_id`, `type`, `direction`, `status`, `payout_status`;
- payout target: `payout_currency`, `payout_network`, `payout_address`;
- amounts: `amount_ars_cents`, `amount_out`, `amount_out_unit`, `network_fee_out`, and the USDT amounts;
- timing: `expires_at`, `late_watch_until` (nullable), `watch_pending`;
- results: `txid`, `payment_hash`, `error_code`;
- bank details, present after funding only: `alias`, `cvu`.

Funding can raise `amount_ars_cents` by up to 100 cents so that each pending amount is unique. The POS must show the funded amount, never the quoted one.

**Order lifecycle:**

| status | payout_status | watch_pending | Meaning |
|---|---|---|---|
| CREATED | waiting_ars | false | Created, no bank details yet. Expires after 5 min. |
| FUNDING_ISSUED | waiting_ars | true | Bank details issued. `expires_at` is 15 min after funding. |
| EXPIRED | expired | true until `late_watch_until` | The payment window closed, but a late transfer is still detected for up to 60 more minutes. |
| EXPIRED | expired | false | Closed. |
| EXECUTED | sending | true | ARS received, sats being sent. |
| EXECUTED | review | true | A human must look at it. |
| COMPLETED | completed | false | Sats delivered. `payment_hash` is set. |
| SETTLED_TO_BALANCE | settled_to_balance | false | The payout failed. The money went to the merchant's Wapu balance. |

**Polling rule:** poll the order while `watch_pending` is true. A CREATED order does not change on its own, so it is not polled.

**Errors:**

| Status | Typical backend message | What the POS shows |
|---|---|---|
| 400 | `payout_address is required`, `lightning address rejected: …` | the destination or amount is invalid |
| 401 | invalid key | the key is not valid; open config |
| 403 | `crypto purchases are disabled` / `require beta access` / `an active registered user is required` | the account cannot buy (feature off, beta off, inactive) |
| 404 | not found | the order does not exist for this account |
| 409 | busy / no receiver | no liquidity right now; try again in a few minutes |
| 422 | amount too small for the fee / over the Lightning maximum | the amount is out of range |
| 429 | `too many open purchase orders`, `too many purchase orders`, `monthly purchase limit reached` | wait for open orders to expire, or the monthly limit is reached |
| 503 | `lightning address unreachable`, payout provider unavailable | try again later |

**Lightning addresses (LUD-16 only):**

- The address is lowercased and may have a `lightning:` prefix.
- It has exactly one `@`.
- The local part matches `^[a-z0-9\-_.+]{1,64}$`.
- The domain is a fully qualified domain name with an alphabetic top-level domain.
- The backend resolves the address through LNURL. `amount_out` must be within the address's min and max sendable.

**Limits** come from global backend settings:

- minimum ARS 10,000;
- `ln_send_max_sats` 500,000;
- per-account open-order cap, creations per hour and monthly tier.

The POS shows the backend's message when a limit is hit and does not duplicate the limits locally. The only exception is the quote's `min_amount_ars_cents`, used to disable Confirm early.

## User flow

All copy is Spanish source text with English translations (`context.tr`).

0. **Entry.**
   - If no POS user is signed in, the mini-app says a POS user is needed.
   - If the user has no saved key, it opens the config.
1. **Destination.** The operator scans the customer's wallet QR with the existing `TokenScanPage`, or types or pastes the address.
   - Scanned text is normalized: trimmed, lowercased, with the `lightning:` prefix stripped.
   - A BOLT11 invoice or LNURL string is rejected with "Pedile al cliente su lightning address".
   - The format is checked with the backend rules, then the address is resolved with the existing `lnurl.validate`. The operator cannot continue until it resolves.
2. **Amount.** The amount pad is built on the existing `Numpad`. It takes whole pesos by default, with a toggle to sats.
   - `AmountPad` is not reused: it yields only sats at POS rates, and it rewrites the global currency.
   - The quote refreshes 500 ms after the last keypress.

   The screen shows:
   - the sats the customer receives;
   - the effective rate (ARS per BTC);
   - the fee percentage, already included;
   - the estimated network fee;
   - the minimum, when the amount is below it;
   - a banner when `liquidity_ok` is false.

   Confirm is enabled only with a fresh quote that has liquidity and is not below the minimum.
3. **Confirm.** One tap creates the order and then requests funding.
   - If create times out, the POS does not retry. It says the result is unknown and to check Historial.
   - If funding fails, Retry calls funding again, which is safe.
4. **Status.** The status screen polls every 10 s.
   - Waiting for the transfer: alias, CVU and the exact amount with cents, each with a copy button, plus a countdown to `expires_at`.
   - Sending, then "Listo" with the payment hash. Reaching COMPLETED plays the existing paid sound (`AppSounds.play(AppSound.paid)`).
   - In review: tells the operator to keep the order ID.
   - Settled to balance: says the customer did not get the sats and the money is in the merchant's Wapu balance.
   - Expired: if `watch_pending` is still true, says a late transfer is still detected until `late_watch_until`.
   - A CREATED order shows "Pedir datos de transferencia" (request transfer details), which calls funding.
   - Terminal states show a large "Nueva venta" button.
5. **Historial.** The app bar button opens the `/wapu/historial` route.
   - It lists orders: in-progress first (`watch_pending`, or CREATED and not expired), then the rest, keeping the API's order within each group.
   - Tapping an order pops its id back to the sale screen, which opens its status.
6. **Nueva venta.** The app bar button works from every step, except while an order is being created or funded. It asks for confirmation when the current order is FUNDING_ISSUED.
7. **Config.**
   - The key field is obscured. Once a key is saved, it shows only the key's last 4 characters.
   - Saving validates the key with `GET /users/user-settings`. A 401 shows "invalid key"; nothing is saved.
   - After saving, if the switch differs from the account's `beta_version`, the POS sends a PATCH to match the switch.
   - Toggling the switch sends a PATCH immediately.
   - "Olvidar key" (forget key) removes this POS user's credentials.
   - The backend URL must be `https`. Plain `http` is allowed only for localhost and emulator hosts, for development.

## Architecture

New code lives in `lib/features/wapu/`, and each file has one job:

| File | Responsibility |
|---|---|
| `wapu_api.dart` | `WapuApi`: one Dio per base URL and key, with the `X-API-Key` header, a 15 s default timeout and 45 s for create and funding. Parses `WapuQuote` and `WapuOrder`. Maps errors to `WapuApiException(statusCode, message)`, with a `timeout` flag for unknown outcomes. No Flutter imports. |
| `wapu_account.dart` | `WapuAccounts`: per-merchant credentials (`apiKey`, `baseUrl`) in `flutter_secure_storage`, under one JSON map keyed by `merchantAddress.trim().toLowerCase()`. Provides load, save and forget. A failed read, for example while the Keystore is busy, counts as no saved key when loading and deletes nothing, while a save or a forget fails instead of writing over entries it could not read. Each merchant's entry is parsed on its own, so a malformed one is skipped without hiding the others. After Android restores a backup that cannot carry Keystore keys, the plugin resets its own storage (`resetOnError`), and the key is asked for again. |
| `wapu_destination.dart` | Pure helpers: normalize scanned text, validate LUD-16 with the backend regexes, and detect BOLT11 and LNURL strings. |
| `wapu_screen.dart` | The sale flow: destination, then amount, then confirm, then status. App bar actions are Historial, Nueva venta and the gear. Owns the order poller. |
| `wapu_status_view.dart` | Presentation of one order: the state copy, bank details with copy buttons, the countdown and the actions. |
| `wapu_history_screen.dart` | The order list and resume. |
| `wapu_settings_screen.dart` | Config: key, URL, beta switch, forget. |

The mini-app hooks into the existing app through:

- a `MiniappManifest` entry in `lib/features/miniapps/miniapps.dart` (name, subtitle, route, icon), with no new `MiniappRequirement`;
- the routes `/wapu`, `/wapu/historial` and `/wapu/config` in `lib/core/router.dart`;
- registration in `lib/core/flow_lock.dart` as `'/wapu': {'/wapu', '/wapu/historial'}`, so the till can be locked into the mini-app. The config stays out of reach while locked, like Rueda's;
- English entries in `lib/core/i18n.dart`.

It reuses existing pieces:

- `lnurl.validate` for destination checks;
- `TokenScanPage` for QR scanning;
- `Numpad` for amount entry;
- `PosAppBar` (with `lockFlow: '/wapu'`) and `PosBody`;
- `confirmMiniappPin` for the PIN gate;
- `AppSounds.play(AppSound.paid)` when an order completes;
- the copy-to-clipboard and generation-guarded polling idioms of the payment screen.

Bank details, addresses and ids use Material `Text` or `SelectableText`, because the app's own `Text` from `ui.dart` uppercases and shrinks to one line.

No new package is added. `flutter_secure_storage` is already declared in `pubspec.yaml`.

## Error handling

- Every API failure becomes a `WapuApiException`. Screens map it to a message using the status code and a few known substrings of the backend message, and show the backend message as a detail line.
- A 401 anywhere sends the operator to the config.
- Polling failures keep the last known state and retry on the next tick. They never clear the bank details shown to the customer.
- Timers are cancelled in `dispose`. Async results check a generation counter and `mounted` before touching state, so a stale reply from an abandoned order cannot update a new sale.

## Testing

- **API tests** with the `FakeNet` adapter:
  - headers: only `X-API-Key`, plus the JSON content type;
  - query and body shapes, with integer amounts;
  - parsing of the quote, the order and the list;
  - error mapping, including timeouts on create.
- **Credential store tests:** per-merchant isolation, load, save, forget, and the default URL.
- **Pure helper tests:** address normalization, LUD-16 validation, BOLT11 and LNURL detection.
- **Widget tests:**
  - setup is required without a key;
  - the destination gate, with a fake `lnurl`;
  - the debounced quote and the minimum or liquidity gating;
  - confirm leads to the status with bank details and copy buttons;
  - polling transitions to "Listo" and to "settled to balance";
  - a create timeout shows the "check Historial" message;
  - the Nueva venta confirmation;
  - history ordering and resume;
  - the PIN gate on the gear;
  - the beta switch PATCH.
- **CI:** `flutter analyze` and `flutter test --coverage`, with Codecov patch coverage of at least 80%.
- **Live check, not in CI:** before the PR, the API client runs against a local survivors stack with a real Lightning payout of 1000 sats or less to the user's own wallet.

## Risks

- **Abandoned orders hold open-order slots** for up to about 75 min. Ops raises the cap to 20.
- **The create call is not idempotent.** A timeout must never auto-retry.
- **A failed payout settles to the merchant's balance, not the customer's.** The status copy must say so plainly.
- **Release builds with R8 and `flutter_secure_storage`** are not verified. This PR ships a debug APK only.
