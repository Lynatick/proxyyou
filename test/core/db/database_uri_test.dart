import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/database_uri.dart';

void main() {
  test('Windows drive is hierarchical and survives URI parsing with spaces', () {
    for (final scheme in ['proxyyou-db', 'proxyyou-settings']) {
      final uri = Uri(
        scheme: scheme,
        path: databaseUriPath(r'C:\Users\test\My Dir\configurations.db'),
        queryParameters: {'profile': 'p'},
      );
      final decoded = Uri.parse(uri.toString());
      expect(Uri.decodeComponent(decoded.path), '/C:/Users/test/My Dir/configurations.db');
      expect(decoded.hasAuthority, isFalse);
    }
  });
  test('Unix database path stays absolute', () {
    expect(databaseUriPath('/Users/test/My Dir/configurations.db'), '/Users/test/My Dir/configurations.db');
  });
}
