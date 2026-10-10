import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/browser/browser_service.dart';

void main() {
  group('isWebUrl', () {
    test('accepts absolute http(s) addresses only', () {
      expect(BrowserService.isWebUrl('https://www.echopark.com/used-cars'), isTrue);
      expect(BrowserService.isWebUrl('http://example.com'), isTrue);
      expect(BrowserService.isWebUrl('javascript:alert(1)'), isFalse);
      expect(BrowserService.isWebUrl('file:///data/data/x/app_flutter/captures/a.html'), isFalse);
      expect(BrowserService.isWebUrl('data:text/html,<b>x</b>'), isFalse);
      expect(BrowserService.isWebUrl('echopark.com'), isFalse);
      expect(BrowserService.isWebUrl(''), isFalse);
      expect(BrowserService.isWebUrl(null), isFalse);
    });
  });

  group('siteIdFor', () {
    test('matches a curated host exactly or by subdomain, nothing else', () {
      expect(BrowserService.siteIdFor('https://www.echopark.com/used-cars'), 'echopark');
      expect(BrowserService.siteIdFor('https://echopark.com/'), 'echopark');
      expect(BrowserService.siteIdFor('https://m.cars.com/shopping/'), 'cars');
      expect(BrowserService.siteIdFor('https://usedcars.com/'), isNull);
      expect(BrowserService.siteIdFor('https://notcars.com/'), isNull);
      expect(BrowserService.siteIdFor('not a url'), isNull);
    });
  });
}
