import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/lnurl/lnurl_service.dart';

// Ported from card-manager's data/{Jwt,AuthStore,Settings,Api}.kt and
// util/Domain.kt. Same claims, same endpoints, same error texts.

/// Public claims of a LaWallet device token (decoded, not verified).
class JwtClaims {
  const JwtClaims(
      {this.apiUrl, this.scopes = const [], this.pubkey, this.kind, this.exp});

  final String? apiUrl;
  final List<String> scopes;
  final String? pubkey;
  final String? kind;

  /// Seconds since epoch.
  final int? exp;
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.trim().isEmpty ? null : s;
}

bool looksLikeJwt(String token) {
  final parts = token.trim().split('.');
  return parts.length == 3 && parts.every((p) => p.isNotEmpty);
}

/// base64url-decodes the payload; null if not a parseable JWT.
JwtClaims? decodeJwt(String token) {
  try {
    final parts = token.trim().split('.');
    if (parts.length != 3) return null;
    final o = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    if (o is! Map) return null;
    final scopes = o['scopes'];
    final exp = o['exp'];
    return JwtClaims(
      apiUrl: _str(o['apiUrl']),
      scopes: scopes is List ? scopes.map((s) => '$s').toList() : const [],
      pubkey: _str(o['pubkey']),
      kind: _str(o['kind']),
      exp: exp is num ? exp.toInt() : null,
    );
  } catch (_) {
    return null;
  }
}

/// True when `exp` has passed (with a 30s skew). No exp: not expired.
bool isJwtExpired(JwtClaims claims, {int skewSec = 30, DateTime? now}) {
  final exp = claims.exp;
  if (exp == null) return false;
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return exp * 1000 <= ms + skewSec * 1000;
}

/// https by default, no trailing slashes.
String normalizeBaseUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  final withScheme =
      RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed)
          ? trimmed
          : 'https://$trimmed';
  return withScheme.replaceAll(RegExp(r'/+$'), '');
}

/// Best-effort host from any URL-ish payload: drops scheme, path, query,
/// fragment, userinfo, port and a leading `www.`.
/// `https://beta.lawallet.io/api/cards/abc/claim?p=1` → `beta.lawallet.io`
String cardDomain(String raw) {
  final s = raw.trim();
  final i = s.indexOf('://');
  var authority = i < 0 ? s : s.substring(i + 3);
  for (final c in ['/', '?', '#']) {
    final j = authority.indexOf(c);
    if (j >= 0) authority = authority.substring(0, j);
  }
  final at = authority.indexOf('@');
  var host = at < 0 ? authority : authority.substring(at + 1);
  final colon = host.indexOf(':');
  if (colon >= 0) host = host.substring(0, colon);
  if (host.startsWith('www.')) host = host.substring(4);
  return host.trim().isEmpty ? s : host;
}

/// The device-token JWT + the instance base URL, persisted across launches.
/// The token's optional `apiUrl` claim becomes the base URL (else a default),
/// and every API call sends `Authorization: Bearer <jwt>`.
class CardsAuth {
  CardsAuth._();
  static final instance = CardsAuth._();

  static const _keyJwt = 'cards.device_token';
  static const _keyBase = 'cards.base_url';
  static const _keyAutoPrint = 'cards.auto_print';
  static const defaultBase = 'https://beta.lawallet.io';

  String? jwt;
  JwtClaims? claims;
  String baseUrl = defaultBase;

  /// Logged in. Flips the miniapp between login and the tap flow.
  final loggedIn = ValueNotifier(false);

  /// Tapping a card mints + prints the activation QR automatically.
  final autoPrint = ValueNotifier(false);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_keyBase) ?? defaultBase;
    autoPrint.value = prefs.getBool(_keyAutoPrint) ?? false;
    final stored = prefs.getString(_keyJwt);
    if (stored != null) {
      final decoded = decodeJwt(stored);
      if (decoded != null && !isJwtExpired(decoded)) {
        jwt = stored;
        claims = decoded;
      } else {
        await prefs.remove(_keyJwt);
      }
    }
    _loaded = true;
    _emit();
  }

  /// null on success, else `invalid` or `expired`.
  Future<String?> login(String token) async {
    if (!looksLikeJwt(token)) return 'invalid';
    final decoded = decodeJwt(token);
    if (decoded == null) return 'invalid';
    if (isJwtExpired(decoded)) return 'expired';
    final prefs = await SharedPreferences.getInstance();
    final api = decoded.apiUrl;
    if (api != null) {
      baseUrl = normalizeBaseUrl(api);
      await prefs.setString(_keyBase, baseUrl);
    }
    jwt = token;
    claims = decoded;
    await prefs.setString(_keyJwt, token);
    _emit();
    return null;
  }

  void logout() {
    jwt = null;
    claims = null;
    SharedPreferences.getInstance().then((p) => p.remove(_keyJwt));
    _emit();
  }

  void setAutoPrint(bool value) {
    autoPrint.value = value;
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_keyAutoPrint, value));
  }

  bool get isLoggedIn {
    final c = claims;
    return jwt != null && c != null && !isJwtExpired(c);
  }

  /// Instance host for display / lightning-address domain.
  String host() {
    final h = Uri.tryParse(baseUrl)?.host ?? '';
    return h.isNotEmpty ? h : baseUrl.replaceFirst('https://', '');
  }

  void _emit() => loggedIn.value = isLoggedIn;
}

/// SUN proof from a tapped card's NDEF URL query (`p` = encrypted PICC data,
/// `c` = CMAC).
class Sun {
  const Sun(this.p, this.c);
  final String p;
  final String c;
}

/// Card detail for display (subset of the backend `Card`).
class CardDetail {
  const CardDetail({
    required this.id,
    this.imageUrl,
    this.designName,
    required this.status,
    this.lightningAddress,
    this.kind,
    required this.owned,
    required this.disabled,
    this.sun,
  });

  final String id;
  final String? imageUrl;
  final String? designName;
  final String status;
  final String? lightningAddress;
  final String? kind;
  final bool owned;
  final bool disabled;

  /// The fresh tap's SUN proof. Null for manual entry (recovery then needs a
  /// real tap).
  final Sun? sun;
}

/// Owner of a card, from `GET /api/cards/:id/owner`. Addresses are full
/// `user@domain`.
class OwnerSummary {
  const OwnerSummary({
    required this.owned,
    this.pubkey,
    this.primaryAddress,
    this.lightningAddresses = const [],
    this.cards = 0,
    this.remoteWallets = 0,
    required this.cardRecoveryEnabled,
    required this.cardDisabled,
    this.balanceSats,
  });

  final bool owned;
  final String? pubkey;
  final String? primaryAddress;
  final List<String> lightningAddresses;
  final int cards;
  final int remoteWallets;
  final bool cardRecoveryEnabled;
  final bool cardDisabled;

  /// Null when the owner's wallet is unreachable.
  final int? balanceSats;
}

/// Minted ONE_TIME activation (or recovery) token.
class ActivationToken {
  const ActivationToken(this.qrPayload, [this.expiresAt]);
  final String qrPayload;
  final String? expiresAt;
}

class CardsApiException implements Exception {
  CardsApiException(this.message, [this.code = 0]);
  final String message;
  final int code;
  @override
  String toString() => message;
}

/// The server card id from a tapped lnurlw/https scan URL, or a bare id
/// entered by hand.
String resolveCardId(String input) {
  final m = RegExp(r'/api/cards/([^/?]+)').firstMatch(input);
  if (m != null) return m.group(1)!;
  var s = input.trim();
  for (final prefix in ['lnurlw://', 'https://']) {
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
  }
  return s.replaceAll(RegExp(r'^/+|/+$'), '');
}

/// The SUN `p`/`c` hex params of a tapped card URL, or null if either is
/// missing.
Sun? parseSun(String cardUrl) {
  String? param(String name) =>
      RegExp('[?&]$name=([0-9A-Fa-f]+)').firstMatch(cardUrl)?.group(1);
  final p = param('p');
  final c = param('c');
  return p == null || c == null ? null : Sun(p, c);
}

/// Why [cardOwnerAddress] has no address for a tapped card.
enum CardAddressError implements Exception {
  /// The tag is not a LaWallet card: its URL's path has no `/api/cards/<id>`.
  notLaWallet,

  /// The card's instance does not know it (404).
  notFound,

  /// Nobody paired the card, or its owner has no username.
  noAddress,

  /// No answer, an instance too old to tell (400), or a reply that is not a
  /// card's.
  unreadable,
}

/// The client of [cardOwnerAddress]. Someone waits at the counter for it.
final _cardInfo = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 10),
));

/// The lightning address of the owner of the LaWallet card that sent
/// [tapUrl], from the public info of the card's instance: no login.
///
/// The tap's `p` and `c` spend the card, so [tapUrl] is never requested, sent,
/// logged or kept. The info is asked of `…/api/cards/<id>/scan` with
/// `x-request-action: info` and no query, which leaves the card's counter as
/// it was.
///
/// Every instance pays its users at its own host, `<username>@<host>`. Its
/// settings may name a domain of its own, and `<username>@<domain>` is the
/// address given when it resolves to a callback on that same host.
///
/// Throws a [CardAddressError] when there is no address to give. [dio] and
/// [service] stand in for the network in tests.
Future<String> cardOwnerAddress(String tapUrl,
    {Dio? dio, LnurlService? service}) async {
  final uri = Uri.tryParse(tapUrl);
  final host = uri?.host ?? '';
  // The id comes from the path alone, never from the query that holds the SUN.
  final id =
      RegExp(r'/api/cards/([^/]+)').firstMatch(uri?.path ?? '')?.group(1);
  if (host.isEmpty || id == null) throw CardAddressError.notLaWallet;
  final client = dio ?? _cardInfo;
  final Object? info;
  try {
    info = (await client.getUri(
      Uri.https(host, '/api/cards/$id/scan'),
      options: Options(headers: {'x-request-action': 'info'}),
    ))
        .data;
  } catch (e) {
    throw e is DioException && e.response?.statusCode == 404
        ? CardAddressError.notFound
        : CardAddressError.unreadable;
  }
  // The info always says who has the card, if anyone: a reply that does not
  // is not the card's.
  if (info is! Map || !info.containsKey('user')) {
    throw CardAddressError.unreadable;
  }
  final user = info['user'];
  final username = user is Map ? user['username'] : null;
  if (username is! String || username.isEmpty) {
    throw CardAddressError.noAddress;
  }
  try {
    final settings =
        (await client.getUri(Uri.https(host, '/api/settings'))).data;
    final domain = settings is Map ? settings['domain'] : null;
    if (domain is String && domain.trim().isNotEmpty) {
      final address = '$username@${domain.trim().toLowerCase()}';
      final params = await (service ?? lnurl).resolve(address);
      if (Uri.parse(params.callback).host == host) return address;
    }
  } catch (_) {
    // No settings, or a domain that does not pay here: the host does.
  }
  return '$username@$host';
}

/// Authenticated LaWallet API over [CardsAuth.baseUrl]: GET `/api/cards/:id`
/// for the card, POST `…/activation-tokens` `{qrKind:"ONE_TIME"}` to mint the
/// QR. Owned cards also load GET `…/owner`, and RECOVER mints POST
/// `…/recovery-tokens` with the tap's SUN `{p, c}`.
class CardsApi {
  CardsApi({Dio? dio, CardsAuth? auth})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 20),
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            )),
        _auth = auth ?? CardsAuth.instance;

  final Dio _dio;
  final CardsAuth _auth;

  String _cardUrl(String id, [String suffix = '']) =>
      '${_auth.baseUrl}/api/cards/${Uri.encodeQueryComponent(id)}$suffix';

  Future<CardDetail> getCard(String cardUrlOrId, {Sun? sun}) async {
    final id = resolveCardId(cardUrlOrId);
    final o = await _request('GET', _cardUrl(id));
    final design = o['design'] is Map ? o['design'] as Map : const {};
    final username = _str(o['username']);
    final pubkey = _str(o['pubkey']);
    final assigned = username != null || pubkey != null;
    final disabled = o['disabled'] == true;
    return CardDetail(
      id: _str(o['id']) ?? id,
      imageUrl: _str(design['imageUrl']),
      designName: _str(design['description']),
      status: !assigned
          ? 'Not activated'
          : disabled
              ? 'Paused'
              : 'Activated',
      lightningAddress: username == null ? null : '$username@${_auth.host()}',
      kind: _str(o['kind']),
      owned: assigned,
      disabled: disabled,
      sun: sun,
    );
  }

  /// The card owner's summary, or null on an older backend without the
  /// endpoint (404).
  Future<OwnerSummary?> getOwner(String cardId) async {
    final Map o;
    try {
      o = await _request('GET', _cardUrl(cardId, '/owner'));
    } on CardsApiException catch (e) {
      if (e.code == 404) return null;
      rethrow;
    }
    final addresses = o['lightningAddresses'];
    final balance = o['balanceSats'];
    return OwnerSummary(
      owned: o['owned'] == true,
      pubkey: _str(o['pubkey']),
      primaryAddress: _str(o['primaryAddress']),
      lightningAddresses: addresses is List
          ? addresses.map(_str).whereType<String>().toList()
          : const [],
      cards: (o['cards'] as num?)?.toInt() ?? 0,
      remoteWallets: (o['remoteWallets'] as num?)?.toInt() ?? 0,
      cardRecoveryEnabled: o['cardRecoveryEnabled'] == true,
      cardDisabled: o['cardDisabled'] == true,
      balanceSats: balance is num ? balance.toInt() : null,
    );
  }

  Future<ActivationToken> mintActivation(String cardId) async {
    final o = await _request('POST', _cardUrl(cardId, '/activation-tokens'),
        body: {'qrKind': 'ONE_TIME'});
    final qr = _str(o['qrPayload']) ??
        (throw CardsApiException('Activation response missing qrPayload.'));
    return ActivationToken(qr, _str(o['expiresAt']));
  }

  /// Mints a ONE_TIME recovery QR (`…/wallet/activate/<id>?tag=recover`).
  /// Needs the fresh tap's SUN; errors carry the server's reason (recovery
  /// off, tap reused…).
  Future<ActivationToken> mintRecovery(String cardId, Sun sun) async {
    final o = await _request('POST', _cardUrl(cardId, '/recovery-tokens'),
        body: {'p': sun.p, 'c': sun.c}, preferServerMessage: true);
    final qr = _str(o['qrPayload']) ??
        (throw CardsApiException('Recovery response missing qrPayload.'));
    return ActivationToken(qr, _str(o['expiresAt']));
  }

  /// [preferServerMessage]: show the server's `message` for any error code,
  /// not our canned 404/409 text.
  Future<Map> _request(String method, String url,
      {Map<String, Object?>? body, bool preferServerMessage = false}) async {
    final token = _auth.jwt;
    if (token == null) throw CardsApiException('Not authenticated.');
    final Response<String> res;
    try {
      res = await _dio.request<String>(url,
          data: body == null ? null : jsonEncode(body),
          options: Options(method: method, headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          }));
    } on DioException catch (e) {
      throw CardsApiException(e.message ?? e.error?.toString() ?? '$e');
    }
    final code = res.statusCode ?? 0;
    Map? json;
    try {
      final decoded = jsonDecode(res.data ?? '');
      if (decoded is Map) json = decoded;
    } catch (_) {}
    if (code == 401) {
      _auth.logout();
      throw CardsApiException('Session expired — scan a new token.', 401);
    }
    if (code < 200 || code >= 300) {
      // `{ success:false, error:{ message, code } }`; older routes send a
      // top-level `message`.
      final err = json?['error'];
      final serverMessage =
          (err is Map ? _str(err['message']) : null) ?? _str(json?['message']);
      final msg = (preferServerMessage ? serverMessage : null) ??
          switch (code) {
            404 => 'Card not registered.',
            409 => 'Another QR was just issued — try again.',
            _ => serverMessage ?? 'Error (HTTP $code).',
          };
      throw CardsApiException(msg, code);
    }
    return json ?? (throw CardsApiException('Unexpected server response.'));
  }
}
