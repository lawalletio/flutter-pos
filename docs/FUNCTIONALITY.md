# Functionality — screens & flows (parity spec)

Full functional map of the current webapp that the native app must reproduce (v1 excludes
`/picture` and `/extract`). See `PROTOCOL.md` for payment internals and `NATIVE-CONTRACT.md` for
printer/NFC.

## Navigation

```
Home (Lightning Address entry)
└─ Destination hub  (resolves LUD-16 + NIP-05)
   ├─ Cart/Menu  ─┐
   ├─ Paydesk    ─┤→ (Tip?) → Payment
   ├─ Tab        ─┤
   ├─ Tree       ─┘   (Tree also → Scan)
   ├─ Orders
   └─ Admin
   Settings
```

## Screens

### Home
Enter merchant Lightning Address (defaults domain if omitted). If `destination` already stored,
auto-forward to the hub. Clears any in-flight order/LN state on mount. Writes `destination`.

### Destination hub `/{destination}`
Resolves the address (LUD-16 → NIP-05), validates `allowsNostr`; on failure alerts and returns Home.
Shows venue menu card(s) (mapped by address, e.g. `barra@…`→Barra), plus **Cash Register**→Paydesk,
**Ordenes**→Orders, and **Cerrar cuenta**→Tab (only if `tabEnabled`). Writes `destinationLUD06`.

### Cart / Menu
Loads `assets/menus/{name}.json`, groups products by `category_id` (`assets/categories.json`).
Add/remove items; sticky footer with item count + "Ver carrito" summary sheet; "Cobrar {total}".
Converts ARS→SAT via price feed. On checkout: build order → (Tip if `tipEnabled`) → Payment.
Stores `lastCheckoutBack`.

### Paydesk (Cash register)
Numpad + currency selector (SAT/USD/ARS). "Charge" builds an order for the entered amount →
(Tip?) → Payment. Requires `lud06`; alerts+returns if missing.

### Tip (optional, `tipEnabled`)
Shows total; options 5/10/15% or "no tip". Adds a `Propina` line item (`id 999999`, description
`{percentage}%`) and bumps amount, then → Payment (preserving `back`/`tab` params).

### Payment `/payment/{orderId}` (core)
States: loading invoice → QR + "waiting for payment" → paid (confetti, "Pago acreditado", auto-print)
→ error. Shows amount in SAT + fiat. Buttons: **Agregar a tab** (if `tabEnabled`), **Solicitar NFC**
(if available), **Cancel**, **Check event** (emergency). Auto-starts NFC card read when invoice ready;
card path = LUD-03 withdraw (see PROTOCOL §5). Dual detection marks paid (PROTOCOL §4). Back →
`back` param / `lastCheckoutBack` / Home, calling `clear()`.

### Orders
Read-only session history from `paymentsCache`, newest first. Per order: id (truncated), timestamp,
amount (sats), paid vs pending, publish status + relay count, zap-receipt status + relay count, items,
"Copiar ID". Empty state when none.

### Tab (`tabEnabled`)
Open customer accounts from `tabs`. Each card: name, sats, items, fiat; tap → pay/close that tab
(→ Tip? → Payment with `tab={id}`). "Clear all" with confirm sheet. On successful payment the tab is
removed.

### Tree (Arbolito)
Card-to-card transfer. Scan recipient by NFC or QR (→ Scan), resolve via `fetchLNURL`, enter amount
on numpad, "Transferir" → (Tip?) → Payment. Stores `lastCheckoutBack='/tree'`.

### Scan
Full-screen QR scanner (rear camera). Detects transfer type, strips `lightning:`; routes to
`/tree?data=…`. Cancel → Tree.

### Admin
Card diagnostics + format. Auto-reads a tapped card: state chips (Init/Asociada/Activada/Delegada),
identity `@lawallet.ar`, balance (sats), design, nonce. "Iniciar Formateo" → capture security tap →
"Formatear tarjeta" → POST card reset, show admin QR. (PROTOCOL §6.)

### Settings
Toggles: **tip** (`tipEnabled`), **tab** (`tabEnabled`). Nostr relays: suggested list with
checkboxes, add custom, reset to default; at least one required. Writes `nostrRelays`.

## Persistence keys (native store)
`destination`, `destinationLUD06`, `config` (currency + hideBalance), `prices`, `nostrPrivateKey`
(secure), `nostrRelays`, `tipEnabled`, `tabEnabled`, `tabs`, `paymentsCache`, `lastCheckoutBack`.

## Currencies & helpers
`SAT | USD | ARS`. Converter uses yadio BTC rates (PROTOCOL §7). Numpad logic (multi-currency,
max length, delete/concat) and formatters (`roundToDown`, `decimalsToUse`, `formatToPreference`)
port from `useNumpad`/`useCurrencyConverter`/`lib/formatter`.

## Out of scope for v1
`/extract` (order export/print to `lacrypta.masize.com/api/extract`) and `/picture` (AI image-gen via
`/api/generate-image`). Both can be re-added later; picture needs a backend endpoint.
