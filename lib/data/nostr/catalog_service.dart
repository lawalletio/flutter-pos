import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/config/settings_state.dart';
import '../../domain/order/product.dart';
import 'catalog.dart';
import 'coupon_events.dart';
import 'event.dart';
import 'profile_service.dart';
import 'relay_list.dart';
import 'relay_pool.dart';
import 'relay_sync_service.dart';
import 'signer.dart';

/// Verify every event's id and BIP-340 signature.
///
/// Top-level so it can run through [compute]. `authors:` filtering is a request
/// to the relay, not a guarantee, and `pubkey` is just a JSON string — only the
/// signature makes a price non-forgeable. The relay list is editable in
/// Settings and ships third-party defaults, so this is a money path fed by
/// user-configurable strangers.
List<NostrEvent> verifyAll(List<NostrEvent> events) =>
    [for (final e in events) if (verifyEvent(e)) e];

/// What the catalog read learned. Deliberately data, not a decision — the menu
/// screen decides what to render from it.
@immutable
class CatalogResult {
  final String address;

  /// null when NIP-05 did not resolve — the merchant has no nostr identity at
  /// all, which is a very different thing from having one we could not reach.
  final String? pubkey;

  final List<Product> products;
  final List<({int id, String name})> categories;
  final int unsellable;

  /// No relay produced a single event or EOSE. We learned nothing.
  final bool unreachable;

  final bool fromCache;
  final DateTime? fetchedAt;

  /// Where this merchant's coupons are claimed, when they have authorised a
  /// service. Null means no coupon button at the till.
  ///
  /// Deliberately NOT cached with the catalog: the announcement is how a
  /// merchant moves or revokes their coupon service, so it is read live.
  final CouponDiscovery? coupons;

  const CatalogResult({
    required this.address,
    required this.pubkey,
    this.products = const [],
    this.categories = const [],
    this.unsellable = 0,
    this.unreachable = false,
    this.fromCache = false,
    this.fetchedAt,
    this.coupons,
  });

  bool get hasNostrIdentity => pubkey != null;
  bool get hasProducts => products.isNotEmpty;
}

@immutable
class _CachedCatalog {
  /// Also the map key. Keyed by ADDRESS, not pubkey, so the menu can be painted
  /// BEFORE the NIP-05 round trip that would reveal the pubkey — otherwise a
  /// cold start stares at a spinner through an HTTP call for a catalog already
  /// sitting on disk. The pubkey is still checked before anything is trusted.
  final String address;
  final String pubkey;
  final DateTime at;
  final List<Product> products;
  final List<({int id, String name})> categories;
  final int unsellable;

  const _CachedCatalog({
    required this.address,
    required this.pubkey,
    required this.at,
    required this.products,
    required this.categories,
    required this.unsellable,
  });
}

/// The merchant's NIP-99 catalog, resolved from their Lightning Address.
///
/// The address doubles as a NIP-05 identifier: `barra@lacrypta.ar` resolves at
/// `https://lacrypta.ar/.well-known/nostr.json` to the pubkey whose kind-30402
/// and kind-30405 events are the menu.
///
/// NOTE: no cross-check against the LNURL-pay response is performed. LUD-16 and
/// NIP-05 resolve on the merchant's own domain, so a host that can rewrite one
/// can rewrite the other; and the `nostrPubkey` that lacrypta.ar returns is the
/// shared LaWallet zap-provider key (identical for every address), not the
/// merchant's identity — comparing against it would reject every merchant.
class CatalogService {
  static const _key = 'catalogCache';

  /// Bumped when the stored shape changes; an older blob is dropped rather than
  /// misread. v1 was a single slot, which lost the cache on every merchant
  /// switch — the reason this is a map now.
  static const _schema = 2;

  /// How many merchants keep a cached menu. A till may legitimately rotate
  /// between a handful (barra, comida, merch…) in one shift, and each switch
  /// used to wipe the previous one. Bounded because Android reads the whole
  /// prefs file into memory at startup.
  static const _maxMerchants = 6;

  /// In-memory freshness only. The persisted copy has no TTL: it is the offline
  /// floor, and something stale-but-labelled beats an empty menu mid-shift.
  static const _ttl = Duration(minutes: 5);

  final ValueNotifier<CatalogResult?> notifier =
      ValueNotifier<CatalogResult?>(null);

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Cached menus by address, read from disk once and mutated in place.
  /// Keeping it in memory also removes a disk read from every menu open and
  /// makes the read-modify-write on save race-free.
  Map<String, _CachedCatalog>? _cacheMem;

  /// Event ids that already passed id+signature verification.
  ///
  /// A nostr event id IS the hash of its content, and the signature covers that
  /// id, so "this id verified once" stays true forever — re-checking it is pure
  /// waste. That matters now that the menu revalidates on every open: BIP-340 in
  /// pure Dart costs real milliseconds per event (much worse in a debug build,
  /// and on a low-end ARM till), and re-verifying an unchanged 34-event catalog
  /// on every open was enough to starve the UI thread into an ANR.
  final Set<String> _verifiedIds = <String>{};

  /// Merchant relay set per pubkey (NIP-65 + NIP-05 hints + the till's own),
  /// resolved once per merchant rather than on every menu open.
  final Map<String, List<RelayEntry>> _relaysByPubkey = {};

  /// The merchant whose catalog we have already replicated this session.
  /// Replication runs when the SELECTED MERCHANT changes, not on every
  /// revalidation — it is idempotent, but re-walking every relay on each menu
  /// open is noise the operator did not ask for.
  String? _syncedPubkey;

  String? _loadedAddress;
  DateTime? _loadedAt;
  String? _inFlightAddress;
  Future<void>? _inFlight;

  CatalogResult? get result => notifier.value;

  /// Load the catalog for [address] if it is missing or stale.
  Future<void> ensureLoaded(String address) {
    final a = address.trim().toLowerCase();

    if (_inFlight != null && _inFlightAddress == a) return _inFlight!;

    final fresh = _loadedAddress == a &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < _ttl &&
        notifier.value != null;
    if (fresh) return Future.value();

    _inFlightAddress = a;
    return _inFlight = _load(a).whenComplete(() {
      _inFlight = null;
      _inFlightAddress = null;
    });
  }

  /// Re-ask the relays, ignoring the [_ttl].
  ///
  /// The menu calls this every time it opens: a merchant can reprice or delist
  /// between two customers, and the TTL that keeps the warm-up and the hub
  /// cheap would otherwise serve that stale price for a full five minutes.
  ///
  /// No "we just asked" floor. [ensureLoaded]'s `_inFlight` already collapses
  /// calls that overlap a fetch in progress, which is the only case that
  /// actually duplicates work — once a fetch has finished, re-asking is the
  /// whole point.
  ///
  /// Fire-and-forget: whatever is on screen stays there until an answer
  /// arrives, and [notifier] delivers it.
  Future<void> revalidate(String address) {
    _loadedAt = null;
    return ensureLoaded(address);
  }

  Future<void> _load(String address) async {
    final cached = await _readCache(address);

    // Show the cached menu straight away, before the NIP-05 lookup. Matching on
    // address rather than pubkey is the whole point: the pubkey is what that
    // lookup is for, and waiting for it means a spinner over data we already
    // have. The pubkey is still checked below before anything is trusted.
    if (cached != null &&
        cached.products.isNotEmpty &&
        notifier.value?.hasProducts != true) {
      _publish(CatalogResult(
        address: address,
        pubkey: cached.pubkey,
        products: cached.products,
        categories: cached.categories,
        unsellable: cached.unsellable,
        fromCache: true,
        fetchedAt: cached.at,
      ));
    }

    final identity = await nostrProfile.resolveNip05(address);
    if (identity == null) {
      // No nostr identity. An authoritative answer, and the only case where
      // falling back to a bundled menu is safe.
      _publish(CatalogResult(address: address, pubkey: null));
      _markLoaded(address);
      return;
    }
    final pubkey = identity.pubkey;

    // Paint the cached catalog immediately, then revalidate behind it — but
    // only when there is nothing better on screen already. During a
    // revalidation the menu is showing live products, and re-publishing the
    // cache would flash the "sin conexión" banner over good data for the length
    // of a relay round trip.
    final showing = notifier.value;
    final alreadyLive = showing != null &&
        showing.pubkey == pubkey &&
        showing.hasProducts &&
        !showing.fromCache;
    if (!alreadyLive && cached != null && cached.pubkey == pubkey) {
      _publish(CatalogResult(
        address: address,
        pubkey: pubkey,
        products: cached.products,
        categories: cached.categories,
        unsellable: cached.unsellable,
        fromCache: true,
        fetchedAt: cached.at,
      ));
    }

    // The merchant's own NIP-65 relays merged with the till's, deduplicated by
    // normalised url. Their relays come first: that is where their catalog
    // actually lives, and the till's defaults are only a safety net.
    final entries = _relaysByPubkey[pubkey] ??= await relaySync.discoverRelays(
      pubkey: pubkey,
      hints: identity.relays,
      defaults: appSettings.value.relays,
    );
    final relays = readUrls(entries);

    final fetched = await fetchEvents(
      [
        {
          'kinds': [kindProduct, kindCategory, kindDeletion],
          'authors': [pubkey],
        },
        // Their coupon announcement. A separate filter, narrowed by `d`: kind
        // 30078 is shared by every app, and the merchant panel's other entries
        // under it are NIP-44 sealed configs we have no business fetching.
        {
          'kinds': [kindAppData],
          'authors': [pubkey],
          '#d': [couponDiscoveryD],
        },
      ],
      relays: relays,
      timeout: const Duration(seconds: 8),
    );

    if (fetched.unreachable) {
      // We learned nothing. Keep whatever the cache holds, never overwrite it
      // with emptiness, and do not mark the load fresh so the next menu open
      // retries instead of sitting on a failure for the whole TTL.
      _publish(CatalogResult(
        address: address,
        pubkey: pubkey,
        products: cached?.pubkey == pubkey ? cached!.products : const [],
        categories: cached?.pubkey == pubkey ? cached!.categories : const [],
        unsellable: cached?.pubkey == pubkey ? cached!.unsellable : 0,
        unreachable: true,
        fromCache: cached?.pubkey == pubkey,
        fetchedAt: cached?.pubkey == pubkey ? cached!.at : null,
        coupons: notifier.value?.pubkey == pubkey ? notifier.value!.coupons : null,
      ));
      _loadedAddress = address;
      _loadedAt = null;
      return;
    }

    // Only pay for events we have not already cleared.
    final fresh = [
      for (final e in fetched.events)
        if (e.id != null && !_verifiedIds.contains(e.id)) e,
    ];
    if (fresh.isNotEmpty) {
      final passed = await compute(verifyAll, fresh);
      if (_verifiedIds.length > 2000) _verifiedIds.clear(); // cheap bound
      for (final e in passed) {
        _verifiedIds.add(e.id!);
      }
    }
    final verified = [
      for (final e in fetched.events)
        if (e.id != null && _verifiedIds.contains(e.id)) e,
    ];
    if (verified.length != fetched.events.length) {
      // Loud on purpose: a serialization mismatch would otherwise make a
      // product vanish from the menu without a trace.
      debugPrint('CatalogService: dropped '
          '${fetched.events.length - verified.length} event(s) failing '
          'id/signature verification');
    }

    final projection = buildCatalog(verified, pubkey);
    final discovery = latestCouponDiscovery(verified, pubkey);
    final now = DateTime.now();

    // An incomplete read is NOT a smaller catalog — it is a partial view, and
    // it is never authoritative. Catalog data is routinely split across relays:
    // here relay.damus.io was the sole holder of every category and every
    // kind-5 deletion while the products sat on relay.lacrypta.ar, so its
    // intermittent upgrade failure made the menu alternate between 4 products
    // with categories and 5 products with none — the extra one being a product
    // the merchant had deleted.
    //
    // Deliberately not a "did the counts shrink?" test. A fragment missing only
    // the deletions has MORE products and the same categories, so a count check
    // waves it through and resurrects deleted items. If the read was not
    // complete, the only safe move is to keep what we already have.
    if (!fetched.complete) {
      final previous = notifier.value;
      if (previous != null && previous.pubkey == pubkey && previous.hasProducts) {
        debugPrint('CatalogService: partial read '
            '(${projection.products.length}p/${projection.categories.length}c) '
            '— keeping the previous catalog');
        // The COUPON ANNOUNCEMENT still lands, even though the catalog does
        // not. Completeness matters for the catalog because it is assembled
        // from many events and a fragment missing the deletions resurrects
        // products the merchant removed. The announcement is a single
        // addressable event: one relay that answered has told us the whole
        // thing, and withholding it would hide the coupon button for good on a
        // till whose relay list contains anything unreachable — which, with
        // relay.damus.io refusing to upgrade, is this till.
        if (discovery?.claimUrl != previous.coupons?.claimUrl) {
          _publish(CatalogResult(
            address: address,
            pubkey: pubkey,
            products: previous.products,
            categories: previous.categories,
            unsellable: previous.unsellable,
            fromCache: previous.fromCache,
            fetchedAt: previous.fetchedAt,
            coupons: discovery,
          ));
        }
        _loadedAddress = address;
        _loadedAt = null; // retry on the next open rather than sit on a fragment
        return;
      }
      // Nothing better to show yet: render the fragment, but never persist it.
    }

    _publish(CatalogResult(
      address: address,
      pubkey: pubkey,
      products: projection.products,
      categories: projection.categories,
      unsellable: projection.unsellable,
      fetchedAt: now,
      coupons: discovery,
    ));

    // Only a complete read earns the cache. A fragment on disk outlives the
    // network blip that produced it and is read back as gospel on the next cold
    // start, which is how a good catalog gets permanently replaced by five
    // uncategorised products.
    if (!fetched.complete && _syncedPubkey != pubkey) {
      // Say so rather than leaving the icon absent and the operator guessing.
      final silent = entries
          .where((e) => !fetched.idsByRelay.containsKey(e.url))
          .map((e) => e.url.replaceFirst('wss://', ''))
          .join(', ');
      relaySync.skipped(
        address: address,
        relays: entries,
        reason: silent.isEmpty
            ? 'la lectura de relays quedó incompleta'
            : 'no respondieron $silent',
      );
    }

    if (fetched.complete) {
      await _writeCache(address, pubkey, projection, now);
      _markLoaded(address);
      // Replicate on a complete read only: "relay X is missing event Y" is only
      // a safe claim when we know what every relay holds.
      if (_syncedPubkey != pubkey) {
        _syncedPubkey = pubkey;
        relaySync
            .sync(
              address: address,
              relays: entries,
              // Only the live catalog + its deletions; superseded versions
              // of a repriced product are not worth re-litigating.
              events: liveEventsFor(verified, pubkey),
              idsByRelay: fetched.idsByRelay,
            )
            .ignore();
      }
    } else {
      _loadedAddress = address;
      _loadedAt = null; // not authoritative; re-ask next time
    }
  }

  void _publish(CatalogResult r) => notifier.value = r;

  void _markLoaded(String address) {
    _loadedAddress = address;
    _loadedAt = DateTime.now();
  }

  /// Every cached menu, keyed by address.
  Future<Map<String, _CachedCatalog>> _allCached() async {
    final memo = _cacheMem;
    if (memo != null) return memo;

    final out = <String, _CachedCatalog>{};
    try {
      final raw = (await _p).getString(_key);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        // A v1 blob is a single merchant in a different shape. Dropping it
        // costs one cold fetch; misreading it would show the wrong menu.
        if ((j['v'] as num?)?.toInt() == _schema) {
          final entries = (j['entries'] as Map).cast<String, dynamic>();
          for (final e in entries.entries) {
            final v = (e.value as Map).cast<String, dynamic>();
            out[e.key] = _CachedCatalog(
              address: e.key,
              pubkey: v['pubkey'] as String,
              at: DateTime.fromMillisecondsSinceEpoch(
                  (v['at'] as num).toInt() * 1000),
              unsellable: (v['unsellable'] as num?)?.toInt() ?? 0,
              products: [
                for (final p in v['products'] as List)
                  Product.fromJson((p as Map).cast<String, dynamic>()),
              ],
              categories: [
                for (final c in v['categories'] as List)
                  (
                    id: ((c as Map)['id'] as num).toInt(),
                    name: c['name'] as String,
                  ),
              ],
            );
          }
        }
      }
    } catch (e) {
      // One try/catch around the WHOLE blob — deliberately not the per-item
      // salvage OrdersStore uses. Losing one order row from history is
      // survivable; silently dropping one expensive product from a menu is a
      // money bug.
      debugPrint('CatalogService: unreadable cache, ignoring ($e)');
      out.clear();
    }
    return _cacheMem = out;
  }

  Future<_CachedCatalog?> _readCache(String address) async =>
      (await _allCached())[address];

  /// Store this merchant's menu, keeping the other merchants' intact.
  ///
  /// `description` is deliberately NOT persisted: nothing renders it, and on a
  /// real catalog it is by far the largest field (a few kilobytes per product),
  /// which would put hundreds of kilobytes of dead weight into the prefs file
  /// that Android loads at every startup.
  Future<void> _writeCache(
      String address, String pubkey, CatalogProjection p, DateTime at) async {
    try {
      final all = Map<String, _CachedCatalog>.from(await _allCached());
      all[address] = _CachedCatalog(
        address: address,
        pubkey: pubkey,
        at: at,
        unsellable: p.unsellable,
        products: p.products,
        categories: p.categories,
      );

      // Evict the least recently fetched merchants.
      if (all.length > _maxMerchants) {
        final byAge = all.entries.toList()
          ..sort((a, b) => b.value.at.compareTo(a.value.at));
        all
          ..clear()
          ..addEntries(byAge.take(_maxMerchants));
      }
      _cacheMem = all;

      await (await _p).setString(
        _key,
        jsonEncode({
          'v': _schema,
          'entries': {
            for (final e in all.entries)
              e.key: {
                'pubkey': e.value.pubkey,
                'at': e.value.at.millisecondsSinceEpoch ~/ 1000,
                'unsellable': e.value.unsellable,
                'categories': [
                  for (final c in e.value.categories)
                    {'id': c.id, 'name': c.name},
                ],
                'products': [
                  for (final prod in e.value.products)
                    prod.toJson()..remove('description'),
                ],
              },
          },
        }),
      );
    } catch (e) {
      debugPrint('CatalogService: could not persist catalog ($e)');
    }
  }
}

/// App-wide catalog singleton.
final CatalogService catalog = CatalogService();
