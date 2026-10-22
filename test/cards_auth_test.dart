import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/features/cards/cards_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Its own file: CardsAuth loads once per process, and cards_test.dart's
// screens load it first.
void main() {
  test('an expired stored token is dropped on load', () async {
    final payload = base64Url.encode(utf8.encode(jsonEncode({'exp': 10})));
    SharedPreferences.setMockInitialValues(
        {'cards.device_token': 'e30.$payload.sig'});
    await CardsAuth.instance.load();
    expect(CardsAuth.instance.isLoggedIn, isFalse);
    expect(CardsAuth.instance.loggedIn.value, isFalse);
    expect(
        (await SharedPreferences.getInstance()).getString('cards.device_token'),
        isNull);
  });
}
