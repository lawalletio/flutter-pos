import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/flow_lock.dart';

void main() {
  tearDown(() => lockedFlow.value = null);

  test('unlocked, every route goes through', () {
    expect(lockRedirect('/settings'), isNull);
  });

  test('locked to the menu, the checkout passes and the rest bounces', () {
    lockedFlow.value = '/cart';
    for (final path in ['/cart', '/tip', '/payment', '/ruleta']) {
      expect(lockRedirect(path), isNull, reason: path);
    }
    for (final path in ['/', '/hub', '/settings', '/paydesk', '/orders']) {
      expect(lockRedirect(path), '/cart', reason: path);
    }
  });

  test('a locked miniapp keeps players on it', () {
    lockedFlow.value = '/rueda';
    expect(lockRedirect('/rueda'), isNull);
    expect(lockRedirect('/rueda/config'), '/rueda');
  });
}
