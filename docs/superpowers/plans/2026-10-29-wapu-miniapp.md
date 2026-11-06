# Wapu Mini-app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Wapu" mini-app that sells sats over Lightning to a walk-in customer who pays ARS by bank transfer, through the WapuPay ramp-on API and the merchant's API key.

**Architecture:**
- A pure API client (`WapuApi`), a per-merchant credential store (`WapuAccounts`, backed by `flutter_secure_storage`) and pure destination helpers feed three screens: `/wapu` (the sale flow), `/wapu/config` and `/wapu/historial`.
- The sale screen is one stateful widget with internal steps (destination, amount, status). It polls with generation-guarded timers.
- Tests swap the top-level `wapuAccounts` / `wapuApiFor` globals, the way they already swap `lnurl`.

**Tech Stack:** Flutter 3.44.4, Dart >=3.4, dio 5, go_router 17, flutter_secure_storage 10, mobile_scanner 7, intl 0.20.2, flutter_test.

**Spec:** `docs/superpowers/specs/2026-10-29-wapu-miniapp-design.md`

## Global Constraints

**Commands:**
- Run Flutter through a login shell: `bash -lc 'cd <worktree> && flutter …'`. The worktree is `/home/senshi/projects/flutter-pos-worktrees/wapu-miniapp`.
- `flutter analyze` must report **No issues found**. CI fails on infos too.

**Dependencies:** no new packages. `flutter_secure_storage` is already in `pubspec.yaml`. Add no new `MiniappRequirement` value, because `test/miniapps_test.dart` asserts the enum.

**Copy and i18n:**
- UI copy is Spanish source text through `context.tr('…')`.
- Every new Spanish string gets an English entry in the `_en` map in `lib/core/i18n.dart`, under a `// Wapu` section comment.
- Dynamic values (amounts, times, ids) go outside `tr()`, concatenated with the translated static part.

**Text widgets:** alias, CVU, addresses, ids and hashes use Material `Text` (`import 'package:flutter/material.dart' as m;`) or `SelectableText` with `softWrap: true`. The app's `Text` from `lib/core/ui.dart` uppercases and shrinks to one line.

**API rules:**
- Send only the `X-API-Key` header, never `Authorization`.
- Amounts are JSON integers: ARS cents and sats.
- Use a 45 s receive timeout for create and funding, and 15 s for everything else.
- Never retry a create automatically.

**Defaults and keys:**
- The backend URL constant is `kWapuDefaultBaseUrl = 'https://be-prod.wapu.app'`.
- The secure-storage key is `'wapu.accounts'`. It holds a JSON map keyed by `merchantAddress.trim().toLowerCase()`.

**Mini-app manifest:** `name: 'Wapu'`, `sublabel: 'Bitcoin sin KYC'` (English: `'Bitcoin without KYC'`), `route: '/wapu'`, `icon: Icons.currency_bitcoin`.

**Flow lock:** `'/wapu': {'/wapu', '/wapu/historial'}`. The PR #38 review (F8) removed `/wapu/config`, so the config is unreachable while locked.

**Tests:**
- Tests live flat in `test/`, each file with its own fakes; copy `FakeNet` and `FakeLnurl` from `test/cards_test.dart`.
- Reset these in `tearDown`: `lockedFlow`, `miniappPin`, `lnurl`, `merchantAddress`, `wapuAccounts`, `wapuApiFor`.
- Periodic timers must be cancelled before a test ends: finish widget tests with `await tester.pumpWidget(const SizedBox());`.

**Commits:** Conventional Commits, with no AI attribution trailer. Codecov requires patch coverage of at least 80%.

## Review Focus

1. **The merchant switches POS user while `/wapu` is open** (`merchantAddress` changes). The screen must drop the sale and show the new merchant's state, either its saved key or the "configure" state. Pinned in Task 5.
2. **A poll reply arrives after "Nueva venta"** (stale generation). It must not bring the old order back on screen. Pinned in Task 8.
3. **Funding returns a different ARS amount than the quote**, because of the +0..100 cents uniqueness bump. The status must show the funded amount with cents. Pinned in Task 8.
4. **Scanned or pasted text with a `LIGHTNING:` prefix, uppercase and spaces** must be accepted as the same address. Pinned in Tasks 1 and 5.
5. **The key is revoked while the app is in use** (401 in history or during polling). The app must say the key is invalid without crashing and without clearing bank details already on screen. Pinned in Tasks 8 and 9.

---

### Task 1: Destination helpers

**Files:**
- Create: `lib/features/wapu/wapu_destination.dart`
- Test: `test/wapu_destination_test.dart`

**Interfaces:**
- Produces:
  - `enum DestinationKind { lightningAddress, invoice, lnurl, invalid }`
  - `String normalizeDestination(String raw)`
  - `bool isWapuLightningAddress(String normalized)`
  - `DestinationKind classifyDestination(String raw)`

- [ ] **Step 1: Write the failing tests** in `test/wapu_destination_test.dart`:
  - `normalizes case, spaces and the lightning: prefix`: `normalizeDestination('  LIGHTNING:Alice@Example.COM ')` equals `'alice@example.com'`.
  - `accepts backend-valid addresses`: `isWapuLightningAddress` is true for `'alice@walletofsatoshi.com'` and `'a.b-c_d+e@sub.example.co'`.
  - `rejects addresses the backend rejects`: false for each of these:
    - `'alice'`
    - `'a@b@example.com'`
    - `'alice@localhost'`
    - `'alice@example.c0m'`
    - `'al ice@example.com'`
    - `'${'a' * 65}@example.com'`
    - `'alice@-bad.com'`
  - `classifies invoices and lnurls`:
    - `classifyDestination('lightning:LNBC10U1P3XYZ')` is `invoice`;
    - `classifyDestination('lntb1500n1pxyz')` is `invoice`;
    - `classifyDestination('LNURL1DP68GURN8GHJ7')` is `lnurl`;
    - `classifyDestination(' Alice@Example.com ')` is `lightningAddress`;
    - `classifyDestination('hello')` is `invalid`.
- [ ] **Step 2: Run the tests and see them fail**
  - Run: `bash -lc 'cd /home/senshi/projects/flutter-pos-worktrees/wapu-miniapp && flutter test test/wapu_destination_test.dart'`
  - Expected: FAIL to compile, because the file is missing.
- [ ] **Step 3: Implement**, mirroring survivors `parse_lightning_address`:
  - Normalizing means `trim().toLowerCase()`, then dropping a leading `lightning:` and trimming again.
  - The local part matches `^[a-z0-9\-_.+]{1,64}$`.
  - The domain matches `^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`.
  - The text has exactly one `@`.
  - An invoice starts with `lnbc` or `lntb`, and an lnurl starts with `lnurl`. Both checks run on the normalized text.
- [ ] **Step 4: Run the tests and see them pass**, then run `flutter analyze`. Expected: all pass, and analyze reports No issues found.
- [ ] **Step 5: Commit:** `git add lib/features/wapu/wapu_destination.dart test/wapu_destination_test.dart && git commit -m "feat(wapu): add lightning destination helpers"`

### Task 2: API client, models and error copy

**Files:**
- Create: `lib/features/wapu/wapu_api.dart`
- Test: `test/wapu_api_test.dart`

**Interfaces:**
- Produces:
  - `const kWapuDefaultBaseUrl = 'https://be-prod.wapu.app';`
  - `class WapuApiException implements Exception { const WapuApiException(this.message, {this.statusCode, this.timeout = false}); final String message; final int? statusCode; final bool timeout; }`. `message` is the backend `error` string, or a transport description.
  - `class WapuQuote` with:
    - `int` fields `amountArsCents`, `amountOut`, `networkFeeOut`, `totalAmountUsdt`, `feeAmountUsdt` and `minAmountArsCents`;
    - `bool liquidityOk`;
    - `factory WapuQuote.fromJson(Map<String, dynamic>)`;
    - `double get feePercent`, equal to `feeAmountUsdt * 100 / totalAmountUsdt`, or 0;
    - `double get arsPerBtc`, equal to `(amountArsCents / 100) / (amountOut / 1e8)`, or 0.
  - `class WapuOrder` with:
    - `String` fields `id` (from `tentative_id`, via `toString()`), `status`, `payoutStatus` and `payoutAddress`;
    - `int` fields `amountArsCents`, `amountOut` and `networkFeeOut`;
    - `DateTime?` fields `expiresAt` and `lateWatchUntil`, parsed as UTC;
    - `bool watchPending`;
    - `String?` fields `alias`, `cvu`, `paymentHash`, `errorCode` and `type`;
    - `factory WapuOrder.fromJson(Map<String, dynamic>)`;
    - `bool get hasBankDetails`;
    - `bool isInProgress(DateTime now)`, true when `watchPending`, or when status is CREATED and `now` is before `expiresAt`.
  - `class WapuApi` with:
    - `WapuApi({required String baseUrl, required String apiKey, Dio? dio})`;
    - `Future<WapuQuote> quote({int? arsCents, int? sats})`, which throws `ArgumentError` unless exactly one is given;
    - `Future<WapuOrder> createOrder({required String address, int? arsCents, int? sats})`;
    - `Future<WapuOrder> fund(String orderId)`;
    - `Future<WapuOrder> order(String orderId)`;
    - `Future<List<WapuOrder>> orders()`, which keeps only `type == 'crypto_purchase'` when `type` is present;
    - `Future<bool> betaEnabled()`, true when `beta_version` is `true` or `1`;
    - `Future<void> setBeta(bool enabled)`.
  - `WapuApi Function(String baseUrl, String apiKey) wapuApiFor = (b, k) => WapuApi(baseUrl: b, apiKey: k);`. This is non-final, so tests can swap it.
  - `String wapuErrorKey(WapuApiException e, {bool creating = false})` returns the Spanish copy key below. It is pure, with no Flutter import.

**Endpoints**, relative to `baseUrl`:
- `GET /transactions/direct-fiat/quote`, with `type=crypto_purchase`, `payout_currency=SAT`, `payout_network=LIGHTNING`, and `amount_ars_cents` or `amount_out` as a string of digits;
- `POST /transactions/direct-fiat/tentatives`;
- `POST /transactions/direct-fiat/tentatives/{id}/funding`, with body `{}`;
- `GET /transactions/direct-fiat/tentatives/{id}`;
- `GET /transactions/direct-fiat/tentatives`, which returns `{"tentatives": [...]}`;
- `GET /users/user-settings` and `PATCH /users/user-settings` with `{"beta_version": bool}`.

**Dio setup:**
- Build absolute URLs from `baseUrl`, and pass headers and timeouts per request through `Options`. Then an injected test `Dio` behaves the same.
- Use `responseType: ResponseType.plain` and `validateStatus: (_) => true`, then decode JSON by hand, as `CardsApi._request` does.
- A status of 400 or more throws `WapuApiException(body['error'] ?? 'HTTP <code>', statusCode: code)`.
- `DioExceptionType` connectionTimeout, sendTimeout or receiveTimeout throws `WapuApiException('timeout', timeout: true)`. Any other `DioException` throws `WapuApiException(e.message ?? 'network error')`.

**Copy keys returned by `wapuErrorKey`.** Add each key to `_en`, with the English text after the arrow.

| Condition | Spanish key | English entry |
|---|---|---|
| `timeout && creating` | `'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.'` | "We don't know if the order was created. Check the History before retrying." |
| `timeout` | `'El servidor no respondió. Probá de nuevo.'` | "The server did not respond. Try again." |
| 401 | `'La API key no es válida'` | "The API key is not valid" |
| 403 with `beta` in the message | `'Tu cuenta Wapu no tiene Beta features activado'` | "Your Wapu account does not have Beta features on" |
| 403 with `disabled` | `'Las compras están deshabilitadas en Wapu'` | "Purchases are disabled in Wapu" |
| other 403 | `'Tu cuenta Wapu no puede comprar'` | "Your Wapu account cannot buy" |
| 404 | `'La orden no existe'` | "The order does not exist" |
| 409 | `'No hay liquidez disponible ahora. Probá en unos minutos.'` | "No liquidity available right now. Try again in a few minutes." |
| 422 | `'El monto está fuera de los límites'` | "The amount is out of range" |
| 429 with `open` | `'Hay demasiadas órdenes abiertas. Esperá a que venzan.'` | "There are too many open orders. Wait for them to expire." |
| 429 with `monthly` | `'Se alcanzó el límite mensual de compras'` | "The monthly purchase limit was reached" |
| other 429 | `'Demasiados intentos. Esperá un momento.'` | "Too many attempts. Wait a moment." |
| 503 | `'El servicio no está disponible. Probá más tarde.'` | "The service is unavailable. Try again later." |
| anything else | `'No se pudo completar la operación'` | "The operation could not be completed" |

- [ ] **Step 1: Write the failing tests** in `test/wapu_api_test.dart`.
  - Use a `FakeNet` copied from `cards_test.dart`, extended to record each `RequestOptions` in a `requests` list and to optionally throw a given `DioException` for a route.
  - `apiWith(net)` is `WapuApi(baseUrl: 'https://wapu.test', apiKey: 'k', dio: Dio()..httpClientAdapter = net)`.
  - Tests:
    - `quote by sats sends only the API key and amount_out`:
      - the request path ends with `/transactions/direct-fiat/quote`;
      - `queryParameters` equals `{'type': 'crypto_purchase', 'payout_currency': 'SAT', 'payout_network': 'LIGHTNING', 'amount_out': '100'}`;
      - `headers['X-API-Key'] == 'k'`, and the headers have no `Authorization`;
      - the parsed `amountArsCents` and `liquidityOk` match the canned body.
    - `quote by ARS sends amount_ars_cents`: the query has `'amount_ars_cents': '1500000'`.
    - `quote needs exactly one amount`: `apiWith(net).quote()` and `quote(arsCents: 1, sats: 1)` both throw `ArgumentError`.
    - `createOrder posts integer amounts`:
      - the decoded request body equals `{'type': 'crypto_purchase', 'payout_currency': 'SAT', 'payout_network': 'LIGHTNING', 'payout_address': 'alice@example.com', 'amount_ars_cents': 1500000}`;
      - the content type contains `application/json`;
      - `receiveTimeout == const Duration(seconds: 45)`.
    - `fund posts {} and parses bank details`: the path ends with `/tentatives/t1/funding`, and the parsed order has `alias == 'wapu.pagos'`, `cvu == '0000003100000000000001'`, `amountArsCents == 1500037` and `watchPending == true`.
    - `orders keeps only crypto purchases`: the list body has one `crypto_purchase` and one `crypto_sale`, and the result has length 1.
    - `parses timestamps as UTC`: `expiresAt == DateTime.utc(2026, 10, 29, 15, 0)` from `'2026-10-29T15:00:00Z'`, and a null `late_watch_until` gives null.
    - `errors carry backend message and status`: a 429 `{'error': 'too many open purchase orders'}` throws a `WapuApiException` with `statusCode == 429`, and `wapuErrorKey(e)` equals the "too many open orders" key.
    - `a receive timeout is an unknown outcome`: the net throws `DioException(type: DioExceptionType.receiveTimeout, …)`. The exception has `timeout == true`, and `wapuErrorKey(e, creating: true)` equals the "check the History" key.
    - `beta read and write`: GET `{'beta_version': true}` gives `true`, and `setBeta(false)` sends PATCH with body `{'beta_version': false}`.
    - `isInProgress`:
      - CREATED with a future `expiresAt` is true;
      - CREATED with a past `expiresAt` is false;
      - EXPIRED with `watch_pending: true` is true;
      - COMPLETED is false.
    - `wapuErrorKey maps 401, 403-beta, 409, 503 and unknown`, with one `expect` per row of the table.
- [ ] **Step 2: Run the tests and see them fail.** Run `flutter test test/wapu_api_test.dart`; expected: FAIL to compile.
- [ ] **Step 3: Implement** `wapu_api.dart` as specified, and add the `_en` entries for the table.
- [ ] **Step 4: Run the tests and analyze.** Expected: all pass, and No issues found.
- [ ] **Step 5: Commit:** `feat(wapu): add the WapuPay ramp-on API client`

### Task 3: Per-merchant credentials

**Files:**
- Create: `lib/features/wapu/wapu_account.dart`
- Test: `test/wapu_account_test.dart`

**Interfaces:**
- Consumes: `kWapuDefaultBaseUrl` from Task 2.
- Produces:
  - `class WapuCredentials { const WapuCredentials({required this.apiKey, this.baseUrl = kWapuDefaultBaseUrl}); final String apiKey; final String baseUrl; }`
  - `String? normalizeWapuBaseUrl(String raw)`:
    - It trims the text, adds `https://` when there is no scheme, and strips a trailing `/`.
    - It returns null for any scheme other than `https`, except that `http` is allowed for the hosts `localhost`, `127.0.0.1` and `10.0.2.2`.
    - It returns null for empty text or text with no host.
  - `class WapuAccounts { WapuAccounts({FlutterSecureStorage? storage}); Future<WapuCredentials?> load(String merchantAddress); Future<void> save(String merchantAddress, WapuCredentials c); Future<void> forget(String merchantAddress); }`
  - `WapuAccounts wapuAccounts = WapuAccounts();`, non-final so tests can swap it.

**Storage:**
- One secure-storage entry, `'wapu.accounts'`, holds a JSON map from the merchant key to `{apiKey, baseUrl}`. The merchant key is `merchantAddress.trim().toLowerCase()`.
- An empty merchant address loads null and saves nothing.
- A `PlatformException` on read, or malformed JSON, counts as no credentials. In that case, delete the entry.

- [ ] **Step 1: Write the failing tests.** Use `FlutterSecureStorage.setMockInitialValues({})` in `setUp`.
  - `saves and loads per merchant, ignoring case and spaces`: save for `'Shop@LaCrypta.ar '`, then load `'shop@lacrypta.ar'` and get the same `apiKey` and `baseUrl`.
  - `merchants are isolated and forget removes one`: save A and B, forget A; A loads null and B still loads.
  - `unknown or empty merchant loads null`.
  - `malformed storage loads null`: `setMockInitialValues({'wapu.accounts': 'not json'})`.
  - `a failing read counts as no key`: inject a storage whose `read` throws `PlatformException(code: 'x')`. `load` returns null and does not throw.
  - `normalizeWapuBaseUrl`:
    - `' https://be-prod.wapu.app/ '` gives `'https://be-prod.wapu.app'`;
    - `'be-stage.wapu.app'` gives `'https://be-stage.wapu.app'`;
    - `'http://example.com'` gives null;
    - `'http://localhost:5000'` and `'http://10.0.2.2:5000'` are kept;
    - `''` and `'ftp://x.com'` give null.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests and analyze, and see them pass.**
- [ ] **Step 5: Commit:** `feat(wapu): store WapuPay credentials per POS user`

### Task 4: Config screen

**Files:**
- Create: `lib/features/wapu/wapu_settings_screen.dart`
- Test: `test/wapu_settings_screen_test.dart`

**Interfaces:**
- Consumes: `wapuAccounts`, `WapuCredentials`, `normalizeWapuBaseUrl`, `wapuApiFor`, `wapuErrorKey` and `merchantAddress`.
- Produces: `class WapuSettingsScreen extends StatefulWidget { const WapuSettingsScreen({super.key}); }`. It pops with `Navigator.of(context).maybePop(true)` after a save or a forget, so callers reload.

**Behavior:**
- **Loading:** it loads the current merchant's credentials. When credentials exist, it reads `betaEnabled()` to set the switch. Otherwise the switch starts on.
- **API key field:** `Key('wapu-key')`, obscured. With a saved key, the hint is `'Guardada: ••••' + last4`. An empty field on save keeps the saved key.
- **URL field:** `Key('wapu-url')`, prefilled with the saved or default URL, under an `ExpansionTile` titled `'Avanzado'`.
- **Beta switch:** a `SwitchListTile`, `Key('wapu-beta')`, titled `'Beta features'`. With saved credentials, toggling it calls `setBeta(value)` right away. On error it reverts and shows the error key.
- **Save button:** `'Guardar'`, `Key('wapu-save')`.
  1. An invalid URL shows `'La URL tiene que empezar con https://'`.
  2. Otherwise it calls `betaEnabled()` with the candidate key and URL. On a `WapuApiException`, it shows `wapuErrorKey(e)`, saves nothing and stays on the screen.
  3. On success it saves the credentials.
  4. If the switch is on and beta is false, it calls `setBeta(true)`.
  5. It pops.
- **Forget button:** `TextButton` `'Olvidar key'`, `Key('wapu-forget')`. It is shown only with saved credentials. It calls `wapuAccounts.forget(merchant)` and pops.
- **App bar:** `PosAppBar(title: 'Configuración de Wapu', showSettings: false, showSync: false, showInvoiceDebug: false)`.

- [ ] **Step 1: Write the failing widget tests.**
  - Pump `MaterialApp(home: WapuSettingsScreen())` inside a `Navigator` stack, so the pop is observable.
  - Set `merchantAddress.value = 'shop@lacrypta.ar'`, mock secure storage, and swap `wapuApiFor` with a recording `FakeNet` Dio.
  - Tests:
    - `saving validates the key and turns beta on`: GET returns `{beta_version: false}`, then PATCH. Afterwards `wapuAccounts.load` returns the key, the recorded requests are `GET /users/user-settings` and `PATCH {'beta_version': true}`, and the screen popped.
    - `an invalid key is not saved`: a 401 shows `'La API key no es válida'`, and `load` returns null.
    - `plain http is rejected`: URL `'http://example.com'` shows the https message, and no request was sent.
    - `toggling beta with a saved key patches immediately`: the PATCH body is `{'beta_version': false}`.
    - `forget removes the key`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement**, and add the `_en` entries:
  - `'Configuración de Wapu'` → `'Wapu settings'`
  - `'Avanzado'` → `'Advanced'`
  - `'URL del backend'` → `'Backend URL'`
  - `'Guardada: '` → `'Saved: '`
  - `'La URL tiene que empezar con https://'` → `'The URL must start with https://'`
  - `'Olvidar key'` → `'Forget key'`

  `'Beta features'` stays the same in both languages.
- [ ] **Step 4: Run the tests and analyze, and see them pass.**
- [ ] **Step 5: Commit:** `feat(wapu): add the Wapu config screen`

### Task 5: Sale screen shell, destination step and registration

**Files:**
- Create: `lib/features/wapu/wapu_screen.dart`
- Modify:
  - `lib/features/miniapps/miniapps.dart`, to add the manifest after Cards;
  - `lib/core/router.dart`, to add `/wapu` with the child `config`;
  - `lib/core/flow_lock.dart`, to add the `/wapu` entry from Global Constraints;
  - `lib/core/i18n.dart`.
- Test: `test/wapu_screen_test.dart`

**Interfaces:**
- Consumes: Tasks 1-4, `merchantAddress`, `lnurl.validate`, `confirmMiniappPin`, `TokenScanPage` (`lib/features/cards/cards_widgets.dart`) and `PosAppBar`.
- Produces:
  - `class WapuScreen extends StatefulWidget { const WapuScreen({super.key}); }`
  - The private step enum `_Step { destination, amount, status }`.
  - App bar action keys: `Key('wapu-history')` (added in Task 9), `Key('wapu-new-sale')` (Task 8) and `Key('wapu-config')`.

**Behavior:**
- **App bar:** `PosAppBar(title: 'Wapu', lockFlow: '/wapu', showSettings: false, showSync: false, showInvoiceDebug: false, actions: [...])`.
- **Gear:** `Key('wapu-config')`, `Icons.settings_outlined`, wrapped in `ValueListenableBuilder(lockedFlow)` and hidden while locked. Tapping it runs `confirmMiniappPin(context, action: 'Entrar')`. If that returns true and the screen is still mounted, it runs `await context.push('/wapu/config')` and then reloads the credentials.
- **Credentials:** they load per merchant. Listen to `merchantAddress`; when it changes, reset the sale (`_gen++`, cancel timers, back to destination) and reload.
- **Entry states:**
  - Empty merchant shows `'Ingresá con la dirección del comercio para usar Wapu'`.
  - No credentials shows `'Configurá tu API key de Wapu'`, plus a `'Configurar'` button (`Key('wapu-setup')`) that runs the gear action.
    - While the till is locked, the button is replaced by the copy `'Desbloqueá el POS para configurar Wapu'` (English: `'Unlock the POS to set up Wapu'`), as the gear is hidden: the config stays out of reach.
- **Destination step:**
  - A `TextField` (`Key('wapu-destination')`) with hint `'nombre@dominio.com'` and label `'Lightning address del cliente'`.
  - A `'Escanear QR'` button that pushes `TokenScanPage(prompt: context.tr('Escaneá la lightning address del cliente'))` and puts the popped raw text into the field.
  - A `'Continuar'` button (`Key('wapu-continue')`) that classifies the text:
    - `invoice` shows `'Eso es un invoice. Pedile al cliente su lightning address'`;
    - `lnurl` shows `'Eso es un LNURL. Pedile al cliente su lightning address'`;
    - `invalid` shows `'La lightning address no es válida'`;
    - `lightningAddress` runs `await lnurl.validate(normalized)`. A throw shows the exception's message, or `'No se pudo verificar la lightning address'`. Success stores the normalized address and moves to the amount step, which renders a placeholder `SizedBox` until Task 6.
- **Registration:**
  - Add the `MiniappManifest` from Global Constraints after Cards.
  - Add `GoRoute(path: '/wapu', pageBuilder: … WapuScreen(), routes: [GoRoute(path: 'config', pageBuilder: … WapuSettingsScreen())])`.
  - Add the flow-lock entry.

- [ ] **Step 1: Write the failing widget tests.**
  - Pump `MaterialApp.router` with `GoRouter(initialLocation: '/wapu', redirect: (c, s) => lockRedirect(s.uri.path), routes: [/wapu with config child, /hub])`.
  - Use `FakeLnurl` and the mock secure storage.
  - Tests:
    - `asks for a POS user first`: an empty `merchantAddress` shows the sign-in copy.
    - `asks to configure when the merchant has no key`: shows `'Configurá tu API key de Wapu'` and `Key('wapu-setup')`.
    - `the gear asks for the PIN when one is set`: with `miniappPin.value = '1234'`, tapping `Key('wapu-config')` shows `Key('miniapp-pin')`. Cancel stays on `/wapu`; the right PIN opens `WapuSettingsScreen`.
    - `the gear is hidden while locked`: with `lockedFlow.value = '/wapu'`, `Key('wapu-config')` is not found.
    - `rejects invoices and lnurls with a hint`: entering `'lnbc10u1p3xyz'` shows the invoice copy, and `lnurl.validate` was not called.
    - `normalizes and validates the address`: entering `'  LIGHTNING:Alice@Example.COM '` makes `lnurl.validate` receive `'alice@example.com'`, and the destination field is gone, so the step advanced.
    - `switching POS user resets to that user's state`: with merchant A having a key, change `merchantAddress.value` to B, which has no key, and the setup copy appears.
    - `the manifest lists Wapu`: `miniapps.any((m) => m.route == '/wapu' && m.sublabel == 'Bitcoin sin KYC')`.
    - `lock map covers the sale and its history, not the config`: `lockableFlows['/wapu']` is exactly the two paths `/wapu` and `/wapu/historial`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement**, and add the `_en` entries for every new string, including `'Bitcoin sin KYC'` → `'Bitcoin without KYC'`.
- [ ] **Step 4: Run the tests and analyze.** Also run `flutter test test/miniapps_test.dart test/rueda_screen_test.dart` to check that registration broke nothing.
- [ ] **Step 5: Commit:** `feat(wapu): add the Wapu sale screen with destination step`

### Task 6: Amount step with live quote

**Files:**
- Modify: `lib/features/wapu/wapu_screen.dart`
- Test: `test/wapu_screen_test.dart`, adding an `amount` group.

**Interfaces:**
- Consumes: `Numpad({required onDigit, required onBackspace})` (`lib/core/numpad.dart`), `WapuApi.quote` and `wapuErrorKey`.
- Produces:
  - A widget showing the amount pad, keyed `Key('wapu-amount')`.
  - Keys `Key('wapu-mode-ars')` and `Key('wapu-mode-sats')` for the toggle, and `Key('wapu-confirm')` for Confirm.
  - Internal state `int? _arsCents`, `int? _sats` and `WapuQuote? _quote` (later tasks read these).

**Behavior:**
- **Input:** the pad edits a digit string with a 12-digit cap, using the `_digit`/`_back` logic of `amount_pad.dart`.
  - ARS mode (the default): `arsCents = pesos * 100`.
  - Sats mode: `sats = n`.
  - Switching mode clears the digits and the quote.
- **Display:** pesos as `'\$ ' + NumberFormat.decimalPattern('es_AR').format(pesos)`, and sats as `formatToPreference(<sat currency>, n) + ' sats'`.
- **Quote:** 500 ms after the last change, call `quote(arsCents:)` or `quote(sats:)`. A `_quoteGen` counter drops stale replies. A `WapuApiException` shows `wapuErrorKey(e)` and clears the quote.
- **Quote lines:**
  - `'El cliente recibe'` with `amountOut` sats;
  - `'Tipo de cambio'` with `'\$ ' + arsPerBtc` as an es_AR integer, plus `' por BTC'`;
  - `'Comisión incluida'` with `feePercent`, to 2 decimals, then `'%'`;
  - `'Fee de red estimado'` with `networkFeeOut` sats.
- **Gating:**
  - When `amountArsCents < minAmountArsCents`, show `'El mínimo es '` plus the formatted minimum.
  - When `!liquidityOk`, show the 409 copy key.
  - Confirm is enabled only when the quote is fresh, `liquidityOk` is true, and the amount is not below the minimum.
- **Header:** above the pad, show the destination address with an edit icon that returns to the destination step.

- [ ] **Step 1: Write the failing widget tests**, reusing Task 5's harness with a validated destination:
  - `quotes in pesos after the debounce`: tap 1,5,0,0,0, pump 400 ms, and no request yet; pump 200 ms more, and one quote request with `amount_ars_cents: '1500000'`. `'El cliente recibe'` and the sats are shown.
  - `sats mode quotes amount_out`.
  - `stale quotes are ignored`: two edits less than 500 ms apart send a single request; replies are delivered out of order through a delayed `FakeNet` route; the shown sats match the last input.
  - `below the minimum disables confirm`: with `min_amount_ars_cents` above the amount, the minimum copy shows and `Key('wapu-confirm')`'s `onPressed` is null.
  - `no liquidity disables confirm`.
  - `a quote error is shown and confirm stays disabled`: a 422 shows `'El monto está fuera de los límites'`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement**, and add the `_en` entries.
- [ ] **Step 4: Run the tests and analyze, and see them pass.**
- [ ] **Step 5: Commit:** `feat(wapu): quote the sale amount live`

### Task 7: Order status view and formatting

**Files:**
- Create: `lib/features/wapu/wapu_status_view.dart`
- Test: `test/wapu_status_view_test.dart`

**Interfaces:**
- Consumes: `WapuOrder`.
- Produces:
  - `String formatArsCents(int cents)`, which formats es_AR with exactly 2 decimals behind a `'$ '` prefix. For example `formatArsCents(1500037)` is `'$ 15.000,37'`.
  - `String formatCountdown(Duration d)` gives `mm:ss`, clamped at `'00:00'`.
  - `class WapuStatusView extends StatelessWidget { const WapuStatusView({super.key, required this.order, required this.now, this.onRequestFunding, this.onNewSale, this.busy = false}); }`

**Copy per state:** copy buttons say `'Copiar'` and show the snackbar `'Copiado'`. Terminal states (COMPLETED, SETTLED_TO_BALANCE, closed EXPIRED) show a large `'Nueva venta'` button (`Key('wapu-new-sale-big')`) that calls `onNewSale`.

| State | Copy |
|---|---|
| FUNDING_ISSUED | Title `'Esperando la transferencia'`. Rows `'Alias'`, `'CVU'` and `'Monto exacto'` (`formatArsCents(amountArsCents)`), each with a copy button; the amount copies the plain decimal string `'15000.37'`. Hint `'Transferí exactamente este monto, con centavos'`. `'Vence en '` + `formatCountdown(expiresAt - now)`. |
| CREATED, not expired | `'Orden creada'`, plus a `'Pedir datos de transferencia'` button (`Key('wapu-fund')`) that calls `onRequestFunding`. |
| EXPIRED with `watchPending` | `'Venció el plazo'`, plus `'Si el cliente ya transfirió, lo seguimos buscando hasta las '` + `HH:mm`, the local time of `lateWatchUntil`. |
| EXPIRED, or CREATED past `expiresAt` | `'Orden vencida'` |
| EXECUTED + `sending` | `'Pago recibido. Enviando los sats…'` |
| EXECUTED + `review` | `'En revisión'`, plus `'Guardá el ID de la orden: '` + id |
| COMPLETED | `'¡Listo! El cliente recibió '` + sats + `' sats'`, with `paymentHash` in a `SelectableText` |
| SETTLED_TO_BALANCE | `'No se pudieron enviar los sats'`, plus `'El monto quedó en tu saldo de Wapu.'` |
| any other status | the raw `status` |

- [ ] **Step 1: Write the failing tests:**
  - `formatArsCents` gives `'$ 15.000,37'` for 1500037 and `'$ 0,05'` for 5.
  - `formatCountdown` gives `'14:59'` for 899 s and `'00:00'` for -3 s.
  - A widget test for each table row, with a fixed `now`, asserting the copy.
  - FUNDING_ISSUED: tapping the amount's copy button puts `'15000.37'` on the clipboard. Mock `SystemChannels.platform` the way existing tests mock the clipboard, or check `Clipboard.getData` after `TestDefaultBinaryMessengerBinding` setup.
  - `onRequestFunding` and `onNewSale` fire.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement**, and add the `_en` entries.
- [ ] **Step 4: Run the tests and analyze, and see them pass.**
- [ ] **Step 5: Commit:** `feat(wapu): show the order status with bank details`

### Task 8: Confirm, poll and new sale

**Files:**
- Modify: `lib/features/wapu/wapu_screen.dart`
- Test: `test/wapu_screen_test.dart`, adding a `status` group.

**Interfaces:**
- Consumes: `WapuApi.createOrder`, `fund` and `order`; `WapuStatusView`; `wapuErrorKey(e, creating: true)`; and `AppSounds.play(AppSound.paid)` from `lib/core/sounds.dart`.
- Produces:
  - `Future<void> _resume(String orderId)`, used by Task 9.
  - The `Key('wapu-new-sale')` app bar action.

**Behavior:**
- **Confirm:**
  1. Increment `_gen`, then call `createOrder` with the destination and the amount from the current mode.
  2. On a `WapuApiException`, show `wapuErrorKey(e, creating: true)` and stay on the amount step.
  3. On success, move to the status step with the created order, then call `fund(id)`.
  4. A funding error shows its copy key; the CREATED view's `'Pedir datos de transferencia'` button retries funding.
  5. After funding succeeds, start polling.
- **Polling:**
  - `Timer.periodic(10 s)` runs while `order.watchPending`. Each tick calls `order(id)` and drops the reply when the generation changed or the widget is unmounted.
  - On error it keeps the last order: a 401 shows the copy key above the view and keeps the bank details.
  - Polling stops when `!watchPending`.
  - A transition into COMPLETED calls `AppSounds.play(AppSound.paid)` once.
  - A 1 s `Timer.periodic` repaints the countdown while the status is FUNDING_ISSUED.
  - Cancel every timer in `dispose` and on a new sale.
- **Nueva venta (new sale):**
  - Tapping `Key('wapu-new-sale')` while the order is FUNDING_ISSUED shows a dialog titled `'Nueva venta'` with `'La orden queda abierta hasta que venza. La podés retomar desde el Historial.'` and the actions `'Cancelar'` and `'Nueva venta'`.
  - In every other state, or after confirming the dialog, it resets: `_gen++`, cancel timers, and clear the address, amount, quote and order. It returns to the destination step.

- [ ] **Step 1: Write the failing widget tests:**
  - `confirm creates, funds and shows the funded amount`: the quote said 1500000 and funding returned 1500037. The screen shows `'$ 15.000,37'`, the alias and the CVU, and the request order is quote, create, funding.
  - `a create timeout says to check the history and does not retry`: exactly one create request, and the "check the History" copy is shown.
  - `funding failure offers a retry`: funding first returns 503, then 201. The CREATED view shows `Key('wapu-fund')`, and tapping it shows the bank details.
  - `polling advances to done and plays once`: detail replies FUNDING_ISSUED, then EXECUTED, then COMPLETED, pumped 10 s apart. `'¡Listo!'` shows, and polling stops: there are no more requests after another 30 s.
  - `a stale poll does not resurrect the old order` (Review Focus 2): delay a poll reply, tap new sale while it is in flight, then deliver it. The destination field is visible and the alias is not.
  - `401 while polling keeps the bank details` (Review Focus 5).
  - `new sale asks before abandoning a waiting order`: the dialog appears. Cancel keeps the alias; confirm shows `Key('wapu-destination')`.
  - Each test ends with `await tester.pumpWidget(const SizedBox())`.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement**, and add the `_en` entries.
- [ ] **Step 4: Run the tests and analyze, and see them pass.**
- [ ] **Step 5: Commit:** `feat(wapu): create, fund and follow the order`

### Task 9: History and resume

**Files:**
- Create: `lib/features/wapu/wapu_history_screen.dart`
- Modify:
  - `lib/core/router.dart`, to add the `historial` child under `/wapu`;
  - `lib/features/wapu/wapu_screen.dart`, to add the `Key('wapu-history')` action;
  - `lib/core/i18n.dart`.
- Test: `test/wapu_history_screen_test.dart`

**Interfaces:**
- Consumes: `wapuAccounts`, `wapuApiFor`, `WapuApi.orders`, `WapuOrder.isInProgress`, `formatArsCents`, `wapuErrorKey` and `_resume` (Task 8).
- Produces: `class WapuHistoryScreen extends StatefulWidget { const WapuHistoryScreen({super.key}); }`. Selecting a row pops its id with `context.pop(order.id)`.

**Behavior:**
- **List:** in-progress orders come first (`isInProgress(DateTime.now())`), stable within each group.
- **Rows:** each row (`Key('wapu-order-<id>')`) shows the ARS amount, the sats, the destination address and a short status label:
  - `'En curso'` for in-progress orders;
  - `'Completada'` for COMPLETED;
  - `'Vencida'` for EXPIRED;
  - `'En tu saldo'` for SETTLED_TO_BALANCE;
  - the raw status otherwise.
- **Empty:** `'Todavía no hay órdenes'`.
- **Error:** the copy key, plus `'Reintentar'`, which reloads.
- **App bar:** `PosAppBar(title: 'Historial', showSettings: false, showSync: false, showInvoiceDebug: false)`.
- **Resume:** the sale screen's history action runs `final id = await context.push<String>('/wapu/historial');`. When `id != null && mounted`, it calls `_resume(id)`, which increments `_gen`, fetches `order(id)`, shows the status step and starts polling when `watchPending`.

- [ ] **Step 1: Write the failing tests:**
  - `lists in-progress orders first`: the API returns [COMPLETED a, FUNDING_ISSUED b, EXPIRED-with-watch c]. The rendered keys are in the order b, c, a.
  - `empty history`.
  - `a revoked key shows the invalid-key message` (Review Focus 5): a 401 shows `'La API key no es válida'`.
  - `tapping an order resumes it on the sale screen`: route harness at `/wapu`, tap `Key('wapu-history')`, tap `Key('wapu-order-b')`. The sale screen shows b's alias and polls `/tentatives/b`.
  - `history is reachable while locked`: with `lockedFlow.value = '/wapu'`, pushing `/wapu/historial` is not redirected.
- [ ] **Step 2: Run the tests and see them fail.**
- [ ] **Step 3: Implement**, and add the `_en` entries.
- [ ] **Step 4: Run the tests and analyze, and see them pass.**
- [ ] **Step 5: Commit:** `feat(wapu): list orders and resume them`

### Task 10: Full verification and debug APK

**Files:** none new. Fix only what the checks surface, in the files that own the failure.

- [ ] **Step 1: Analyze and test with coverage.**
  - Run: `bash -lc 'cd /home/senshi/projects/flutter-pos-worktrees/wapu-miniapp && flutter analyze && flutter test --coverage'`
  - Expected: No issues found, and all tests pass, the 259 existing ones plus the new ones.
- [ ] **Step 2: Check i18n parity.** Every `context.tr('…')` literal under `lib/features/wapu/` must have an `_en` key. Check with an `rg` over both files. Expected: no missing key, except those equal in both languages (`'Wapu'`, `'Beta features'`, `'Alias'`, `'CVU'`).
- [ ] **Step 3: Check patch coverage.** For each file under `lib/features/wapu/`, `coverage/lcov.info` lines hit divided by lines found must be at least 0.8. Add tests in the owning test file where it is lower.
- [ ] **Step 4: Build the debug APK.**
  - Run: `bash -lc 'cd /home/senshi/projects/flutter-pos-worktrees/wapu-miniapp && flutter build apk --debug'`
  - Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.
- [ ] **Step 5: Commit** any fixes with `fix(wapu): …` or `test(wapu): …` messages.
