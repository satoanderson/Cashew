import 'dart:convert';
import 'dart:io';

import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/simplefinReviewPage.dart';
import 'package:budget/pages/simplefinSettingsPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/languageMap.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/simplefinService.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  int syncPhase = 1;
  String? lastAuthHeader;

  setUpAll(() async {
    sharedPreferences = await SharedPreferences.getInstance();
    database = await constructDb('simplefin_e2e_test');
    await loadCurrencyJSON();
    await loadLanguageNamesJSON();
    await initializeSettings();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/claim') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('http://user1:pass1@127.0.0.1:$port/api');
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path == '/api/accounts') {
        lastAuthHeader = request.headers.value(HttpHeaders.authorizationHeader);
        final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final txs = <Map<String, dynamic>>[
          {
            'id': 'tx-1',
            'posted': nowEpoch - 3600,
            'amount': '-5.50',
            'description': 'Coffee Shop',
            'memo': 'Latte',
            'pending': false,
          },
          {
            'id': 'tx-2',
            'posted': nowEpoch - 1800,
            'amount': '-20.00',
            'description': 'Unknown Store',
            'memo': 'Misc',
            'pending': false,
          },
          {
            'id': 'tx-pending',
            'posted': nowEpoch - 600,
            'amount': '-10.00',
            'description': 'Pending Hold',
            'memo': '',
            'pending': true,
          },
        ];
        if (syncPhase >= 2) {
          txs.add({
            'id': 'tx-3',
            'posted': nowEpoch - 60,
            'amount': '-4.25',
            'description': 'Coffee Shop',
            'memo': 'Espresso',
            'pending': false,
          });
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'errors': <String>[],
            'accounts': [
              {
                'id': 'acc-checking-1',
                'name': 'Checking',
                'currency': 'USD',
                'balance': '150.00',
                'available-balance': '150.00',
                'balance-date': nowEpoch,
                'transactions': txs,
              },
            ],
          }));
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() async {
    syncPhase = 1;
    lastAuthHeader = null;
    await database.delete(database.simplefinConnections).go();
    await database.delete(database.transactions).go();
    await database.delete(database.wallets).go();
    await database.delete(database.associatedTitles).go();
    await database.delete(database.categories).go();

    await database.into(database.categories).insert(
          CategoriesCompanion.insert(
            categoryPk: const drift.Value('cat-dining'),
            name: 'Dining',
            colour: const drift.Value('0xFFFF0000'),
            iconName: const drift.Value('cutlery.png'),
            order: 0,
            income: const drift.Value(false),
          ),
        );
  });

  testWidgets(
    'SimpleFIN full Android e2e: claim, link, sync, review, learn, reconcile, dedupe, delete',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: getLightTheme(),
          home: Stack(
            children: [
              const SimplefinSettingsPage(),
              GlobalSnackbar(key: snackbarKey),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Claim setup token via UI
      final token = base64Encode(utf8.encode('http://127.0.0.1:$port/claim'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Connection Label (optional)'),
        'My Bank',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'SimpleFIN Setup Token'),
        token,
      );
      await tester.tap(find.text('Connect SimpleFIN'));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('My Bank (active)'), findsOneWidget);
      expect(find.text('Checking'), findsOneWidget);

      final expectedAuth = 'Basic ${base64Encode(utf8.encode('user1:pass1'))}';
      expect(lastAuthHeader, expectedAuth);

      // Verify Android FlutterSecureStorage persisted the Access URL
      final conn =
          await database.select(database.simplefinConnections).getSingle();
      final storedSecret =
          await FlutterSimplefinSecretStore().read(conn.secureStorageKey);
      expect(storedSecret, 'http://user1:pass1@127.0.0.1:$port/api');

      // 2. Link account to a new Wallet via UI dialog
      await tester.tap(find.text('Link Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Mapping'));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('USD • Linked to Checking'), findsOneWidget);

      // 3. Manual Sync Now via UI
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('2 transactions to review'), findsOneWidget);
      expect(find.text('Bank: 150.00 • Ledger: -25.50'), findsOneWidget);
      expect(find.text('Reconcile'), findsOneWidget);

      // 4. Open Review Queue, recategorize Coffee Shop (Save & Learn), confirm Unknown Store
      await tester.tap(find.text('2 transactions to review'));
      await tester.pumpAndSettle();

      expect(find.byType(SimplefinReviewPage), findsOneWidget);
      expect(find.text('Coffee Shop'), findsOneWidget);
      expect(find.text('Unknown Store'), findsOneWidget);
      expect(find.text('Pending Hold'), findsNothing);

      // Recategorize Coffee Shop -> Dining
      final coffeeTile = find.ancestor(
        of: find.text('Coffee Shop'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: coffeeTile, matching: find.byIcon(Icons.edit_outlined)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dining').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save & Learn'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Confirm Unknown Store
      final unknownTile = find.ancestor(
        of: find.text('Unknown Store'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: unknownTile,
          matching: find.byIcon(Icons.check_circle_outline),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(
        find.text('All synced transactions have been reviewed.'),
        findsOneWidget,
      );

      // Navigate back to SimpleFIN Settings
      Navigator.of(tester.element(find.byType(SimplefinReviewPage))).pop();
      await tester.pumpAndSettle();

      // 5. Reconcile balance delta via UI
      await tester.tap(find.text('Reconcile'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.text('Reconcile'), findsNothing);
      expect(find.text('Bank: 150.00 • Ledger: 150.00'), findsOneWidget);

      // 6. Second sync: deduplicates tx-1 & tx-2, imports tx-3 with learned Dining category
      syncPhase = 2;
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('1 transactions to review'), findsOneWidget);
      final tx3 = await (database.select(database.transactions)
            ..where((t) => t.simplefinTransactionId.equals('tx-3')))
          .getSingle();
      expect(tx3.categoryFk, 'cat-dining');
      expect(tx3.simplefinUnreviewed, isTrue);

      // 7. Delete connection preserves Wallet and Transactions
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('No SimpleFIN connections yet.'), findsOneWidget);
      final walletsAfterDelete = await database.select(database.wallets).get();
      final txsAfterDelete = await database.select(database.transactions).get();
      expect(walletsAfterDelete.length, 1);
      expect(txsAfterDelete.length, 4); // tx-1, tx-2, balance correction, tx-3
    },
  );
}
