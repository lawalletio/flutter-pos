import 'dart:convert';

/// Bech32 encoding of an LNURL (LUD-06). Unlike BIP-173 bech32 this has **no
/// 90-char length limit**, so a self-contained encoder is used. Returns the
/// lowercase `lnurl1…` string, or null if the input can't be encoded.
String? encodeLnurl(String url) {
  final words = _convertBits(utf8.encode(url), 8, 5, true);
  if (words == null) return null;
  const hrp = 'lnurl';
  final combined = [...words, ..._createChecksum(hrp, words)];
  final sb = StringBuffer('${hrp}1');
  for (final d in combined) {
    sb.write(_charset[d]);
  }
  return sb.toString();
}

const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int _polymod(List<int> values) {
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if (((top >> i) & 1) == 1) chk ^= gen[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String hrp) {
  final out = <int>[];
  for (final c in hrp.codeUnits) {
    out.add(c >> 5);
  }
  out.add(0);
  for (final c in hrp.codeUnits) {
    out.add(c & 31);
  }
  return out;
}

List<int> _createChecksum(String hrp, List<int> data) {
  final values = [..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
  final mod = _polymod(values) ^ 1;
  return List<int>.generate(6, (i) => (mod >> (5 * (5 - i))) & 31);
}

List<int>? _convertBits(List<int> data, int from, int to, bool pad) {
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    if (value < 0 || (value >> from) != 0) return null;
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) out.add((acc << (to - bits)) & maxv);
  } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
    return null;
  }
  return out;
}
