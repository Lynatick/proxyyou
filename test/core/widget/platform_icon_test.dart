import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/widget/platform_icon.dart';

void main() {
  test('Windows navigation, connection and subscription commands use Fluent contours', () {
    expect(PlatformIcon.resolve(Icons.settings_rounded, TargetPlatform.windows), FluentIcons.settings_24_regular);
    expect(PlatformIcon.resolve(Icons.power_settings_new, TargetPlatform.windows), FluentIcons.power_24_regular);
    expect(PlatformIcon.resolve(Icons.refresh, TargetPlatform.windows), FluentIcons.arrow_clockwise_24_regular);
    expect(PlatformIcon.resolve(Icons.network_check, TargetPlatform.windows), FluentIcons.gauge_24_regular);
    expect(PlatformIcon.resolve(FluentIcons.flash_24_filled, TargetPlatform.windows), FluentIcons.flash_24_regular);
    expect(PlatformIcon.resolve(null, TargetPlatform.windows), isNull);
  });

  test('other platforms and unknown custom icons retain their glyphs', () {
    const custom = IconData(0xe001, fontFamily: 'custom');
    for (final platform in TargetPlatform.values) {
      if (platform != TargetPlatform.windows) {
        expect(PlatformIcon.resolve(Icons.settings_rounded, platform), Icons.settings_rounded);
        expect(PlatformIcon.resolve(FluentIcons.flash_24_filled, platform), FluentIcons.flash_24_filled);
      }
      expect(PlatformIcon.resolve(custom, platform), custom);
    }
  });

  testWidgets('Windows icon preserves size, color, direction and accessibility label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const Scaffold(
          body: PlatformIcon(
            Icons.settings_rounded,
            size: 28,
            color: Colors.green,
            semanticLabel: 'Настройки',
            textDirection: TextDirection.rtl,
          ),
        ),
      ),
    );
    final rich = tester.widget<RichText>(
      find.descendant(of: find.byType(PlatformIcon), matching: find.byType(RichText)),
    );
    final span = rich.text as TextSpan;
    expect(span.text, String.fromCharCode(FluentIcons.settings_24_regular.codePoint));
    expect(span.style!.fontSize, 28);
    expect(span.style!.color, Colors.green);
    expect(find.bySemanticsLabel('Настройки'), findsOneWidget);
    expect(tester.getSize(find.byType(PlatformIcon)), const Size(28, 28));
  });

  testWidgets('Android icon renders the original glyph', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: PlatformIcon(Icons.settings_rounded)),
      ),
    );
    final rich = tester.widget<RichText>(
      find.descendant(of: find.byType(PlatformIcon), matching: find.byType(RichText)),
    );
    expect((rich.text as TextSpan).text, String.fromCharCode(Icons.settings_rounded.codePoint));
  });
}
