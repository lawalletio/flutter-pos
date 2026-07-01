# Parity checklist (webapp → native)

Walk every row on the physical CS30Pro before release. ☐ = pending, ☑ = verified.

## Setup & navigation
- ☐ Home: enter address, default domain, auto-forward when `destination` stored
- ☐ Hub: LUD-16 + NIP-05 resolve; `allowsNostr` failure alerts + returns Home
- ☐ Hub: venue menu card mapping (barra/comida/cafe/bitnaria/merch/test)
- ☐ Hub: Cash Register / Ordenes / Tab (tab only when `tabEnabled`)
- ☐ Back-navigation + `lastCheckoutBack` behaviour across all flows

## Ordering
- ☐ Menu loads from JSON, grouped by category; add/remove; cart sheet totals
- ☐ ARS→SAT conversion matches webapp for sample carts
- ☐ Paydesk numpad: currency switch, max length, delete, charge
- ☐ Tip: 5/10/15% + skip; `Propina` line item (id 999999) + amount bump

## Payment (core)
- ☐ Invoice QR renders; amount shown in SAT + fiat
- ☐ Path A: zap receipt (9735) confirmed on ≥2 relays → paid
- ☐ Path B: LUD-21 `settled` poll → paid; `settled` resets on new invoice
- ☐ Emergency "Check event": LUD-21 12× + forced 9735 fetch
- ☐ NFC card tap → lnurlw → withdraw callback pulls payment (LUD-03)
- ☐ Auto-print once on paid; confetti; no double print
- ☐ Add-to-tab flow; tab removed on successful close

## History & tabs
- ☐ Orders list: statuses + relay counts + copy id
- ☐ Tabs: open accounts, pay/close, clear-all confirm

## Card / transfer / admin
- ☐ Tree: NFC + QR recipient scan, amount, transfer
- ☐ Scan: QR decode + routing
- ☐ Admin: card state chips, identity/balance/nonce, format + reset POST

## Settings & persistence
- ☐ tip/tab toggles persist and gate screens
- ☐ Relay add/remove/reset; ≥1 required
- ☐ All persistence keys survive app restart (see FUNCTIONALITY.md)

## Native
- ☐ Print layout matches (logo, BTC/USD, block, date, items, TOTAL block, message, QR)
- ☐ Paper-out retry; status handling
- ☐ NFC availability query; read cancel; UTF-8/16 NDEF decode

## Non-functional
- ☐ Cold start < webapp; smooth 60fps numpad/scroll
- ☐ Offline: cached menus/prices/orders usable
- ☐ i18n es/en parity
