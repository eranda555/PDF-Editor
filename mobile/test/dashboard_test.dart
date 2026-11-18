import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hundred_percent_pdf/core/database/app_database.dart';
import 'package:hundred_percent_pdf/core/theme/app_theme.dart';
import 'package:hundred_percent_pdf/features/home/dashboard_widgets.dart';
import 'package:hundred_percent_pdf/features/home/home_screen.dart';
import 'package:hundred_percent_pdf/features/tools/local_tools_screen.dart';

class _Documents extends Fake implements AppDatabase {
  @override
  Future<List<Map<String, dynamic>>> documents() async => [
    {'name': 'Example.pdf', 'path': 'example.pdf'},
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pdf_suite/imports'),
          (_) async => [],
        );
  });

  for (final (width, scale) in [
    (320.0, 1.0),
    (390.0, 1.0),
    (430.0, 1.0),
    (320.0, 2.0),
  ]) {
    testWidgets(
      'Dashboard keeps two columns at width $width and scale $scale',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: HomeScreen(database: _Documents()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PdfGoWordmark), findsOneWidget);
        final bar = find.byType(AppBar);
        final overlay = tester
            .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.descendant(
                of: bar,
                matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
              ),
            )
            .value;
        expect(overlay.statusBarColor, Colors.transparent);
        expect(overlay.statusBarIconBrightness, Brightness.dark);
        expect(overlay.statusBarBrightness, Brightness.light);
        expect(
          Theme.of(tester.element(bar)).appBarTheme.backgroundColor,
          Colors.white,
        );
        final first = tester.getRect(
          find.widgetWithText(ToolCard, 'Merge PDF'),
        );
        final second = tester.getRect(
          find.widgetWithText(ToolCard, 'Split PDF'),
        );
        expect(first.top, second.top);
        expect(first.right, lessThan(second.left));
        expect(first.width, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('Search and categories preserve tool routes and file history', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: HomeScreen(database: _Documents()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'split');
    await tester.pumpAndSettle();
    expect(find.byType(ToolCard), findsOneWidget);
    await tester.tap(find.text('Split PDF'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LocalToolsScreen>(find.byType(LocalToolsScreen))
          .initialTool,
      'Split by ranges',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Workflows'));
    await tester.pumpAndSettle();
    expect(find.byType(ToolCard), findsOneWidget);
    expect(find.text('Recipes & Chains'), findsOneWidget);
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('Example.pdf'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);
  });
}
