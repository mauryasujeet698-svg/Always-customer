import 'package:flutter_test/flutter_test.dart';
import 'package:allways_customer/core/theme/app_theme.dart';

void main() {
  test('ALLways theme preserves the brand green', () {
    expect(AllwaysTheme.green, const Color(0xFF087B3E));
  });

  test('light and dark themes can be created', () {
    expect(AllwaysTheme.light.brightness, Brightness.light);
    expect(AllwaysTheme.dark.brightness, Brightness.dark);
  });
}
