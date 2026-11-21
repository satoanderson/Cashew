import 'dart:convert';
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/simplefinService.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/open.dart';

class InMemorySimplefinSecretStore implements SimplefinSecretStore {
  final Map<String, String> _storage = {};

  @override
  Future<void> delete(String key) async {
    _storage.remove(key);
  }

  @override
  Future<String?> read(String key) async => _storage[key];

  @override
  Future<void> write(String key, String value) async {
    _storage[key] = value;
  }

  Map<String, String> get entries => Map.unmodifiable(_storage);
}

void main() {
  setUpAll(() {
    open.overrideFor(
      OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'),
    );
  });

  late FinanceDatabase db;
  late InMemorySimplefinSecretStore secretStore;

  setUp(() {
    db = FinanceDatabase(NativeDatabase.memory());
    secretStore = InMemorySimplefinSecretStore();
  });

  tearDown(() async {
    await db.close();
  });

  group('Ticket 01: SimpleFIN Setup Token claim and account listing', () {
    test('claims a base64 setup token, stores access URL in secure store, and lists accounts', () async {
      const claimUrl = 'https://bridge.simplefin.org/claim/test-token-123';
      final setupToken = base64Encode(utf8.encode(claimUrl));
      const accessUrl = 'https://user123:pass456@bridge.simplefin.org/simplefin';

      final mockClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.toString() == claimUrl) {
          return http.Response(accessUrl, 200);
        }
        if (request.method == 'GET' &&
            request.url.toString() == 'https://bridge.simplefin.org/simplefin/accounts') {
          final expectedAuth = 'Basic ${base64Encode(utf8.encode('user123:pass456'))}';
          expect(request.headers['Authorization'], expectedAuth);
          return http.Response(
            jsonEncode({
              'errors': <String>[],
              'accounts': [
                {
                  'id': 'ACT-1',
                  'name': 'Main Checking',
                  'currency': 'USD',
                  'balance': '1250.50',
                  'available-balance': '1200.00',
                  'balance-date': 1700000000,
                  'transactions': [],
                },
                {
                  'id': 'ACT-2',
                  'name': 'Rewards Card',
                  'currency': 'USD',
                  'balance': '-340.25',
                  'balance-date': 1700000000,
                  'transactions': [],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      final connection = await service.claimSetupToken(
        setupToken,
        label: 'My Bank',
      );

      expect(connection.label, 'My Bank');
      expect(connection.status, 'active');
      expect(secretStore.entries[connection.secureStorageKey], accessUrl);

      final connections = await service.getConnections();
      expect(connections, hasLength(1));

      final response = await service.fetchAccounts(connection.connectionPk);
      expect(response.errors, isEmpty);
      expect(response.accounts, hasLength(2));
      expect(response.accounts[0].id, 'ACT-1');
      expect(response.accounts[0].name, 'Main Checking');
      expect(response.accounts[0].currency, 'USD');
      expect(response.accounts[0].balance, 1250.50);
      expect(response.accounts[1].id, 'ACT-2');
      expect(response.accounts[1].balance, -340.25);
    });

    test('deleting a connection removes its secret and DB row without deleting Wallets or Transactions', () async {
      const claimUrl = 'https://bridge.simplefin.org/claim/delete-test';
      final setupToken = base64Encode(utf8.encode(claimUrl));
      const accessUrl = 'https://u:p@bridge.simplefin.org/simplefin';

      final mockClient = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(accessUrl, 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      final connection = await service.claimSetupToken(setupToken, label: 'Delete Me');

      // Seed a local wallet to verify it survives connection deletion
      await db.into(db.wallets).insert(
        WalletsCompanion.insert(
          walletPk: const drift.Value('wallet-keep'),
          name: 'Local Checking',
          order: 0,
        ),
      );

      await service.deleteConnection(connection.connectionPk);

      expect(secretStore.entries, isEmpty);
      expect(await service.getConnections(), isEmpty);
      final wallets = await db.select(db.wallets).get();
      expect(wallets, hasLength(1));
      expect(wallets.first.walletPk, 'wallet-keep');
    });
  });

  group('Ticket 02: 1:1 Wallet mapping and currency validation', () {
    test('links a SimpleFIN account to an existing Wallet with matching currency and defaults startDate to Today', () async {
      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: MockClient((_) async => http.Response('', 200)),
      );

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-1'),
              label: 'Bank',
              secureStorageKey: 'k1',
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-1'),
              name: 'Existing USD',
              currency: const drift.Value('usd'),
              order: 0,
            ),
          );

      final account = SimplefinAccountData(
        id: 'acct-1',
        name: 'Bank Checking',
        currency: 'USD',
        balance: 500.0,
      );

      final now = DateTime.now();
      final linked = await service.linkAccountToExistingWallet(
        connectionPk: 'conn-1',
        account: account,
        walletPk: 'w-1',
      );

      expect(linked.simplefinConnectionFk, 'conn-1');
      expect(linked.simplefinAccountId, 'acct-1');
      expect(linked.simplefinSyncStartDate, isNotNull);
      expect(linked.simplefinSyncStartDate!.year, now.year);
      expect(linked.simplefinSyncStartDate!.month, now.month);
      expect(linked.simplefinSyncStartDate!.day, now.day);
    });

    test('rejects linking when ISO currencies do not match', () async {
      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: MockClient((_) async => http.Response('', 200)),
      );

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-1'),
              label: 'Bank',
              secureStorageKey: 'k1',
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-cad'),
              name: 'CAD Wallet',
              currency: const drift.Value('cad'),
              order: 0,
            ),
          );

      final account = SimplefinAccountData(
        id: 'acct-usd',
        name: 'US Checking',
        currency: 'USD',
        balance: 100.0,
      );

      expect(
        () => service.linkAccountToExistingWallet(
          connectionPk: 'conn-1',
          account: account,
          walletPk: 'w-cad',
        ),
        throwsA(isA<SimplefinException>()),
      );
    });

    test('creates a new Wallet from a SimpleFIN account with lowercase currency and 30-day default startDate', () async {
      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: MockClient((_) async => http.Response('', 200)),
      );

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-1'),
              label: 'Bank',
              secureStorageKey: 'k1',
            ),
          );

      final account = SimplefinAccountData(
        id: 'acct-eur',
        name: 'Euro Savings',
        currency: 'EUR',
        balance: 2500.0,
      );

      final created = await service.createWalletForAccount(
        connectionPk: 'conn-1',
        account: account,
      );

      expect(created.name, 'Euro Savings');
      expect(created.currency, 'eur');
      expect(created.simplefinConnectionFk, 'conn-1');
      expect(created.simplefinAccountId, 'acct-eur');
      expect(created.simplefinSyncStartDate, isNotNull);
      final diffDays = DateTime.now().difference(created.simplefinSyncStartDate!).inDays;
      expect(diffDays, inInclusiveRange(29, 31));
    });
  });

  group('Ticket 03: Manual Sync Now, settled filtering, deduplication, and categorization', () {
    test('imports settled transactions, skips pending, matches AssociatedTitles, falls back to Unknown, and deduplicates', () async {
      const accessUrl = 'https://u:p@bridge.simplefin.org/simplefin';
      await secretStore.write('k-sync', accessUrl);

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-sync'),
              label: 'Bank',
              secureStorageKey: 'k-sync',
            ),
          );

      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-sync'),
              name: 'Checking',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-sync'),
              simplefinAccountId: const drift.Value('acct-sync'),
              simplefinSyncStartDate: drift.Value(DateTime(2023, 1, 1)),
            ),
          );

      await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              categoryPk: const drift.Value('cat-coffee'),
              name: 'Coffee',
              order: 0,
              income: const drift.Value(false),
            ),
          );

      await db.into(db.associatedTitles).insert(
            AssociatedTitlesCompanion.insert(
              title: 'Blue Bottle',
              categoryFk: 'cat-coffee',
              order: 0,
            ),
          );

      final payload = {
        'errors': <String>[],
        'accounts': [
          {
            'id': 'acct-sync',
            'name': 'Checking',
            'currency': 'USD',
            'balance': '900.00',
            'balance-date': 1700000100,
            'transactions': [
              {
                'id': 'tx-1',
                'posted': 1700000000,
                'amount': '-5.75',
                'description': 'Blue Bottle Coffee',
                'pending': false,
              },
              {
                'id': 'tx-2',
                'posted': 1700000050,
                'amount': '-42.00',
                'description': 'Mystery Merchant LLC',
                'pending': false,
              },
              {
                'id': 'tx-pending',
                'posted': 1700000090,
                'amount': '-19.99',
                'description': 'Pending Hold',
                'pending': true,
              },
            ],
          },
        ],
      };

      final mockClient = MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path.endsWith('/accounts')) {
          return http.Response(jsonEncode(payload), 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      final firstSync = await service.syncConnection('conn-sync', force: true);
      expect(firstSync.importedCount, 2);
      expect(firstSync.skippedPendingCount, 1);
      expect(firstSync.skippedDuplicateCount, 0);

      final txs = await db.select(db.transactions).get();
      expect(txs, hasLength(2));

      final coffeeTx = txs.firstWhere((t) => t.simplefinTransactionId == 'tx-1');
      expect(coffeeTx.categoryFk, 'cat-coffee');
      expect(coffeeTx.amount, -5.75);
      expect(coffeeTx.income, isFalse);
      expect(coffeeTx.simplefinUnreviewed, isTrue);
      expect(coffeeTx.methodAdded, MethodAdded.simplefin);

      final unknownTx = txs.firstWhere((t) => t.simplefinTransactionId == 'tx-2');
      final unknownCat = await (db.select(db.categories)
            ..where((c) => c.categoryPk.equals(unknownTx.categoryFk)))
          .getSingle();
      expect(unknownCat.name, 'Unknown');
      expect(unknownTx.simplefinUnreviewed, isTrue);

      // Second sync with identical payload should deduplicate both transactions
      final secondSync = await service.syncConnection('conn-sync', force: true);
      expect(secondSync.importedCount, 0);
      expect(secondSync.skippedDuplicateCount, 2);
      expect(await db.select(db.transactions).get(), hasLength(2));
    });
  });

  group('Ticket 04: Review queue and AssociatedTitles learning', () {
    test('confirming clears unreviewed flag and recategorizing saves AssociatedTitle for future syncs', () async {
      const accessUrl = 'https://u:p@bridge.simplefin.org/simplefin';
      await secretStore.write('k-rev', accessUrl);

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-rev'),
              label: 'Bank',
              secureStorageKey: 'k-rev',
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-rev'),
              name: 'Checking',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-rev'),
              simplefinAccountId: const drift.Value('acct-rev'),
              simplefinSyncStartDate: drift.Value(DateTime(2023, 1, 1)),
            ),
          );
      await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              categoryPk: const drift.Value('cat-groceries'),
              name: 'Groceries',
              order: 0,
              income: const drift.Value(false),
            ),
          );

      var syncCount = 0;
      final mockClient = MockClient((request) async {
        syncCount++;
        final txs = syncCount == 1
            ? [
                {
                  'id': 'tx-learn-1',
                  'posted': 1700000000,
                  'amount': '-65.00',
                  'description': 'TRADER JOES #104',
                  'pending': false,
                },
              ]
            : [
                {
                  'id': 'tx-learn-2',
                  'posted': 1700000500,
                  'amount': '-32.00',
                  'description': 'TRADER JOES #104',
                  'pending': false,
                },
              ];
        return http.Response(
          jsonEncode({
            'errors': <String>[],
            'accounts': [
              {
                'id': 'acct-rev',
                'name': 'Checking',
                'currency': 'USD',
                'balance': '500.00',
                'transactions': txs,
              },
            ],
          }),
          200,
        );
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      await service.syncConnection('conn-rev', force: true);
      final unreviewed = await service.getUnreviewedTransactions();
      expect(unreviewed, hasLength(1));

      await service.recategorizeAndLearn(
        unreviewed.first.transactionPk,
        'cat-groceries',
      );
      expect(await service.getUnreviewedTransactions(), isEmpty);

      // Next sync with the same merchant should auto-categorize to Groceries
      await service.syncConnection('conn-rev', force: true);
      final allTxs = await db.select(db.transactions).get();
      final secondTx =
          allTxs.firstWhere((t) => t.simplefinTransactionId == 'tx-learn-2');
      expect(secondTx.categoryFk, 'cat-groceries');

      await service.confirmTransactionReviewed(secondTx.transactionPk);
      expect(await service.getUnreviewedTransactions(), isEmpty);
    });
  });

  group('Ticket 05: Bank balance reconciliation and partial error isolation', () {
    test('isolates account-level errors and reconciles ledger delta with Balance Correction', () async {
      const accessUrl = 'https://u:p@bridge.simplefin.org/simplefin';
      await secretStore.write('k-bal', accessUrl);

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-bal'),
              label: 'Bank',
              secureStorageKey: 'k-bal',
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-healthy'),
              name: 'Healthy Checking',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-bal'),
              simplefinAccountId: const drift.Value('acct-healthy'),
              simplefinSyncStartDate: drift.Value(DateTime(2023, 1, 1)),
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-broken'),
              name: 'Broken Savings',
              currency: const drift.Value('usd'),
              order: 1,
              simplefinConnectionFk: const drift.Value('conn-bal'),
              simplefinAccountId: const drift.Value('acct-broken'),
              simplefinSyncStartDate: drift.Value(DateTime(2023, 1, 1)),
            ),
          );

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'errors': ['Broken Savings requires 2FA re-authentication'],
            'accounts': [
              {
                'id': 'acct-healthy',
                'name': 'Healthy Checking',
                'currency': 'USD',
                'balance': '1000.00',
                'balance-date': 1700000100,
                'transactions': [
                  {
                    'id': 'tx-h1',
                    'posted': 1700000000,
                    'amount': '-50.00',
                    'description': 'Dinner',
                    'pending': false,
                  },
                ],
              },
              {
                'id': 'acct-broken',
                'name': 'Broken Savings',
                'currency': 'USD',
                'balance': '500.00',
                'transactions': [],
              },
            ],
          }),
          200,
        );
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      final result = await service.syncConnection('conn-bal', force: true);
      expect(result.importedCount, 1);

      final healthyWallet = await (db.select(db.wallets)
            ..where((w) => w.walletPk.equals('w-healthy')))
          .getSingle();
      final brokenWallet = await (db.select(db.wallets)
            ..where((w) => w.walletPk.equals('w-broken')))
          .getSingle();

      expect(healthyWallet.simplefinBalance, 1000.00);
      expect(healthyWallet.simplefinError, isNull);
      expect(brokenWallet.simplefinError, contains('2FA'));

      // Ledger sum for w-healthy is -50.00, bank balance is 1000.00 -> delta is +1050.00
      final correction = await service.reconcileWalletBalance('w-healthy');
      expect(correction, isNotNull);
      expect(correction!.categoryFk, '0');
      expect(correction.amount, 1050.00);
      expect(correction.income, isTrue);

      // Reconciling again when balanced should be a no-op
      expect(await service.reconcileWalletBalance('w-healthy'), isNull);
    });
  });

  group('Ticket 06: Throttled auto-sync on app launch', () {
    test('skips connections synced under 4h ago, syncs due connections, and isolates HTTP 429/403 errors', () async {
      await secretStore.write('k-recent', 'https://u:p@bridge.simplefin.org/simplefin');
      await secretStore.write('k-due', 'https://u:p@bridge.simplefin.org/simplefin');
      await secretStore.write('k-rate', 'https://u:p@rate.simplefin.org/simplefin');

      final now = DateTime.now();
      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-recent'),
              label: 'Recent',
              secureStorageKey: 'k-recent',
              lastSynced: drift.Value(now.subtract(const Duration(hours: 2))),
            ),
          );
      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-due'),
              label: 'Due',
              secureStorageKey: 'k-due',
              lastSynced: drift.Value(now.subtract(const Duration(hours: 5))),
            ),
          );
      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-rate'),
              label: 'RateLimited',
              secureStorageKey: 'k-rate',
              lastSynced: drift.Value(now.subtract(const Duration(hours: 5))),
            ),
          );

      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-due'),
              name: 'Due Wallet',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-due'),
              simplefinAccountId: const drift.Value('acct-due'),
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-rate'),
              name: 'Rate Wallet',
              currency: const drift.Value('usd'),
              order: 1,
              simplefinConnectionFk: const drift.Value('conn-rate'),
              simplefinAccountId: const drift.Value('acct-rate'),
            ),
          );

      final mockClient = MockClient((request) async {
        if (request.url.host == 'rate.simplefin.org') {
          return http.Response('Too Many Requests', 429);
        }
        return http.Response(
          jsonEncode({
            'errors': <String>[],
            'accounts': [
              {
                'id': 'acct-due',
                'name': 'Due Wallet',
                'currency': 'USD',
                'balance': '200.00',
                'transactions': [],
              },
            ],
          }),
          200,
        );
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      final results = await service.syncAllDueConnections();
      expect(results['conn-recent']?.throttled, isTrue);
      expect(results['conn-due']?.throttled, isFalse);
      expect(results['conn-rate']?.errors.first, contains('429'));

      final rateConn = await (db.select(db.simplefinConnections)
            ..where((c) => c.connectionPk.equals('conn-rate')))
          .getSingle();
      expect(rateConn.status, 'error');
      expect(rateConn.lastError, contains('429'));
    });
  });

  group('Ticket 07: Optional BYOK AI categorization fallback', () {
    test('batches unmatched descriptions to AI without leaking balances or tokens, and falls back to Unknown on invalid/error responses', () async {
      const accessUrl = 'https://secretuser:secretpass@bridge.simplefin.org/simplefin';
      await secretStore.write('k-ai', accessUrl);

      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-ai'),
              label: 'Bank',
              secureStorageKey: 'k-ai',
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-ai'),
              name: 'Checking',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-ai'),
              simplefinAccountId: const drift.Value('acct-ai'),
              simplefinSyncStartDate: drift.Value(DateTime(2023, 1, 1)),
            ),
          );
      await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              categoryPk: const drift.Value('cat-dining'),
              name: 'Dining',
              order: 0,
              income: const drift.Value(false),
            ),
          );

      var aiCalls = 0;
      String? capturedAiBody;
      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.openai.com') {
          aiCalls++;
          capturedAiBody = request.body;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'CHIPOTLE 123': 'Dining',
                      'WEIRD VENDOR': 'NonExistentCategory',
                    }),
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'errors': <String>[],
            'accounts': [
              {
                'id': 'acct-ai',
                'name': 'Checking',
                'currency': 'USD',
                'balance': '9876.54',
                'transactions': [
                  {
                    'id': 'tx-ai-1',
                    'posted': 1700000000,
                    'amount': '-14.25',
                    'description': 'CHIPOTLE 123',
                    'pending': false,
                  },
                  {
                    'id': 'tx-ai-2',
                    'posted': 1700000010,
                    'amount': '-9.00',
                    'description': 'WEIRD VENDOR',
                    'pending': false,
                  },
                ],
              },
            ],
          }),
          200,
        );
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      await service.configureAiCategorization(
        provider: SimplefinAiProvider.openAiCompatible,
        apiKey: 'sk-test-key',
        endpointUrl: 'https://api.openai.com/v1/chat/completions',
        model: 'gpt-4o-mini',
      );

      final result = await service.syncConnection('conn-ai', force: true);
      expect(result.importedCount, 2);
      expect(aiCalls, 1);
      expect(capturedAiBody, isNotNull);
      expect(capturedAiBody, contains('CHIPOTLE 123'));
      expect(capturedAiBody, contains('WEIRD VENDOR'));
      expect(capturedAiBody, contains('Dining'));
      expect(capturedAiBody, isNot(contains('9876.54')));
      expect(capturedAiBody, isNot(contains('secretpass')));
      expect(capturedAiBody, isNot(contains('acct-ai')));

      final txs = await db.select(db.transactions).get();
      final chipotle =
          txs.firstWhere((t) => t.simplefinTransactionId == 'tx-ai-1');
      final weird =
          txs.firstWhere((t) => t.simplefinTransactionId == 'tx-ai-2');

      expect(chipotle.categoryFk, 'cat-dining');
      final weirdCat = await (db.select(db.categories)
            ..where((c) => c.categoryPk.equals(weird.categoryFk)))
          .getSingle();
      expect(weirdCat.name, 'Unknown');
    });

    test('falls back to Unknown gracefully when AI endpoint errors out', () async {
      await secretStore.write('k-ai-err', 'https://u:p@bridge.simplefin.org/simplefin');
      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-ai-err'),
              label: 'Bank',
              secureStorageKey: 'k-ai-err',
            ),
          );
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-ai-err'),
              name: 'Checking',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-ai-err'),
              simplefinAccountId: const drift.Value('acct-ai-err'),
              simplefinSyncStartDate: drift.Value(DateTime(2023, 1, 1)),
            ),
          );

      final mockClient = MockClient((request) async {
        if (request.url.host == 'api.openai.com') {
          return http.Response('Service Unavailable', 503);
        }
        return http.Response(
          jsonEncode({
            'errors': <String>[],
            'accounts': [
              {
                'id': 'acct-ai-err',
                'name': 'Checking',
                'currency': 'USD',
                'balance': '100.00',
                'transactions': [
                  {
                    'id': 'tx-err-1',
                    'posted': 1700000000,
                    'amount': '-5.00',
                    'description': 'SOME SHOP',
                    'pending': false,
                  },
                ],
              },
            ],
          }),
          200,
        );
      });

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );

      await service.configureAiCategorization(
        provider: SimplefinAiProvider.openAiCompatible,
        apiKey: 'sk-test-key',
      );

      final result = await service.syncConnection('conn-ai-err', force: true);
      expect(result.importedCount, 1);

      final txs = await db.select(db.transactions).get();
      final cat = await (db.select(db.categories)
            ..where((c) => c.categoryPk.equals(txs.first.categoryFk)))
          .getSingle();
      expect(cat.name, 'Unknown');
    });

    test('createWalletForAccount enforces 1:1 mapping by unlinking prior Wallet',
        () async {
      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-1to1'),
              label: 'Bank',
              secureStorageKey: 'secret-1to1',
            ),
          );
      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final account = SimplefinAccountData(
        id: 'acc-1',
        name: 'Checking',
        currency: 'USD',
        balance: 100.0,
      );

      final first = await service.createWalletForAccount(
        connectionPk: 'conn-1to1',
        account: account,
      );
      final second = await service.createWalletForAccount(
        connectionPk: 'conn-1to1',
        account: account,
      );

      final reloadedFirst = await (db.select(db.wallets)
            ..where((w) => w.walletPk.equals(first.walletPk)))
          .getSingle();
      expect(reloadedFirst.simplefinConnectionFk, isNull);
      expect(reloadedFirst.simplefinAccountId, isNull);
      expect(second.simplefinConnectionFk, 'conn-1to1');
      expect(second.simplefinAccountId, 'acc-1');
    });

    test('syncConnection propagates generic 2FA/bank errors to linked Wallets',
        () async {
      await db.into(db.simplefinConnections).insert(
            SimplefinConnectionsCompanion.insert(
              connectionPk: const drift.Value('conn-2fa'),
              label: 'Bank',
              secureStorageKey: 'secret-2fa',
            ),
          );
      await secretStore.write('secret-2fa', 'https://u:p@example.com/api');
      await db.into(db.wallets).insert(
            WalletsCompanion.insert(
              walletPk: const drift.Value('w-2fa'),
              name: 'Checking',
              currency: const drift.Value('usd'),
              order: 0,
              simplefinConnectionFk: const drift.Value('conn-2fa'),
              simplefinAccountId: const drift.Value('acc-2fa'),
            ),
          );

      final mockClient = MockClient((_) async => http.Response(
            jsonEncode({
              'errors': ['Institution requires 2FA re-authentication'],
              'accounts': [
                {
                  'id': 'acc-2fa',
                  'name': 'Checking',
                  'currency': 'USD',
                  'balance': '50.00',
                  'balance-date': 1700000000,
                  'transactions': [],
                },
              ],
            }),
            200,
          ));

      final service = SimplefinService(
        db: db,
        secretStore: secretStore,
        httpClient: mockClient,
      );
      await service.syncConnection('conn-2fa', force: true);

      final wallet = await (db.select(db.wallets)
            ..where((w) => w.walletPk.equals('w-2fa')))
          .getSingle();
      expect(wallet.simplefinError, contains('2FA'));
    });
  });
}
