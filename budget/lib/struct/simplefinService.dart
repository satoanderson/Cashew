import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

/// Abstraction over secure credential storage for SimpleFIN Access URLs.
abstract class SimplefinSecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Production secret store backed by [FlutterSecureStorage].
class FlutterSimplefinSecretStore implements SimplefinSecretStore {
  FlutterSimplefinSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum SimplefinAiProvider { none, gemini, openAiCompatible }

class SimplefinAiConfig {
  SimplefinAiConfig({
    required this.provider,
    this.apiKey,
    this.endpointUrl,
    this.model,
  });

  final SimplefinAiProvider provider;
  final String? apiKey;
  final String? endpointUrl;
  final String? model;
}

class SimplefinException implements Exception {
  SimplefinException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode != null
      ? 'SimplefinException($statusCode): $message'
      : 'SimplefinException: $message';
}

class SimplefinTransactionData {
  SimplefinTransactionData({
    required this.id,
    required this.posted,
    required this.amount,
    required this.description,
    required this.memo,
    required this.pending,
  });

  final String id;
  final DateTime posted;
  final double amount;
  final String description;
  final String memo;
  final bool pending;

  factory SimplefinTransactionData.fromJson(Map<String, dynamic> json) {
    final postedEpoch = json['posted'];
    return SimplefinTransactionData(
      id: (json['id'] ?? '').toString(),
      posted: postedEpoch is num
          ? DateTime.fromMillisecondsSinceEpoch(postedEpoch.toInt() * 1000)
          : DateTime.now(),
      amount: double.tryParse((json['amount'] ?? '0').toString()) ?? 0.0,
      description: (json['description'] ?? 'Bank Transaction').toString(),
      memo: (json['memo'] ?? '').toString(),
      pending: json['pending'] == true,
    );
  }
}

class SimplefinSyncResult {
  SimplefinSyncResult({
    this.importedCount = 0,
    this.skippedPendingCount = 0,
    this.skippedDuplicateCount = 0,
    this.errors = const [],
    this.throttled = false,
  });

  final int importedCount;
  final int skippedPendingCount;
  final int skippedDuplicateCount;
  final List<String> errors;
  final bool throttled;
}

class SimplefinAccountData {
  SimplefinAccountData({
    required this.id,
    required this.name,
    required this.currency,
    required this.balance,
    this.availableBalance,
    this.balanceDate,
    this.transactions = const [],
  });

  final String id;
  final String name;
  final String currency;
  final double balance;
  final double? availableBalance;
  final DateTime? balanceDate;
  final List<SimplefinTransactionData> transactions;

  factory SimplefinAccountData.fromJson(Map<String, dynamic> json) {
    final balanceEpoch = json['balance-date'];
    final txList = (json['transactions'] as List<dynamic>?) ?? [];
    return SimplefinAccountData(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Bank Account').toString(),
      currency: (json['currency'] ?? 'USD').toString().toUpperCase(),
      balance: double.tryParse((json['balance'] ?? '0').toString()) ?? 0.0,
      availableBalance: json['available-balance'] != null
          ? double.tryParse(json['available-balance'].toString())
          : null,
      balanceDate: balanceEpoch is num
          ? DateTime.fromMillisecondsSinceEpoch(balanceEpoch.toInt() * 1000)
          : null,
      transactions: txList
          .whereType<Map<String, dynamic>>()
          .map(SimplefinTransactionData.fromJson)
          .toList(),
    );
  }
}

class SimplefinAccountsResponse {
  SimplefinAccountsResponse({
    required this.errors,
    required this.accounts,
  });

  final List<String> errors;
  final List<SimplefinAccountData> accounts;
}

/// Coordinates SimpleFIN Bridge authentication, account discovery, and syncing.
class SimplefinService {
  SimplefinService({
    required this.db,
    SimplefinSecretStore? secretStore,
    http.Client? httpClient,
  })  : _secretStore = secretStore ?? FlutterSimplefinSecretStore(),
        _httpClient = httpClient ?? http.Client();

  final FinanceDatabase db;
  final SimplefinSecretStore _secretStore;
  final http.Client _httpClient;

  /// Exchanges a base64 SimpleFIN Setup Token for an Access URL and persists
  /// the connection record locally.
  Future<SimplefinConnection> claimSetupToken(
    String setupToken, {
    String? label,
  }) async {
    final trimmed = setupToken.trim();
    if (trimmed.isEmpty) {
      throw SimplefinException('Setup token cannot be empty.');
    }

    final String claimUrlString;
    try {
      claimUrlString = utf8.decode(base64Decode(trimmed)).trim();
    } catch (_) {
      throw SimplefinException('Invalid base64 SimpleFIN setup token.');
    }

    final claimUri = Uri.tryParse(claimUrlString);
    if (claimUri == null ||
        (claimUri.scheme != 'https' && claimUri.scheme != 'http')) {
      throw SimplefinException('Setup token decoded to an invalid URL.');
    }

    final response = await _httpClient.post(claimUri);
    if (response.statusCode != 200) {
      throw SimplefinException(
        'Failed to claim SimpleFIN token (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }

    final accessUrl = response.body.trim();
    final accessUri = Uri.tryParse(accessUrl);
    if (accessUri == null || accessUri.userInfo.isEmpty) {
      throw SimplefinException('SimpleFIN returned an invalid Access URL.');
    }

    final connectionPk = const Uuid().v4();
    final secretKey = 'simplefin_access_$connectionPk';
    await _secretStore.write(secretKey, accessUrl);

    final effectiveLabel = (label != null && label.trim().isNotEmpty)
        ? label.trim()
        : accessUri.host;

    await db.into(db.simplefinConnections).insert(
          SimplefinConnectionsCompanion.insert(
            connectionPk: Value(connectionPk),
            label: effectiveLabel,
            secureStorageKey: secretKey,
          ),
        );

    return (db.select(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .getSingle();
  }

  Future<List<SimplefinConnection>> getConnections() {
    return (db.select(db.simplefinConnections)
          ..orderBy([(t) => OrderingTerm.asc(t.dateCreated)]))
        .get();
  }

  /// Fetches external accounts (and optional transactions) from SimpleFIN.
  Future<SimplefinAccountsResponse> fetchAccounts(
    String connectionPk, {
    DateTime? startDate,
  }) async {
    final connection = await (db.select(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .getSingleOrNull();
    if (connection == null) {
      throw SimplefinException('SimpleFIN connection not found.');
    }

    final accessUrl = await _secretStore.read(connection.secureStorageKey);
    if (accessUrl == null || accessUrl.isEmpty) {
      await _updateConnectionStatus(
        connectionPk,
        status: 'needs_reauth',
        lastError: 'Missing stored credentials. Please re-link SimpleFIN.',
      );
      throw SimplefinException('Missing SimpleFIN credentials in secure store.');
    }

    final parsedAccess = Uri.parse(accessUrl);
    final basePath = parsedAccess.path.endsWith('/')
        ? parsedAccess.path.substring(0, parsedAccess.path.length - 1)
        : parsedAccess.path;
    final queryParams = <String, String>{};
    if (startDate != null) {
      queryParams['start-date'] =
          (startDate.millisecondsSinceEpoch ~/ 1000).toString();
    }

    final accountsUri = Uri(
      scheme: parsedAccess.scheme,
      host: parsedAccess.host,
      port: parsedAccess.hasPort ? parsedAccess.port : null,
      path: '$basePath/accounts',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );

    final basicAuth = base64Encode(utf8.encode(parsedAccess.userInfo));
    final response = await _httpClient.get(
      accountsUri,
      headers: {'Authorization': 'Basic $basicAuth'},
    );

    if (response.statusCode != 200) {
      final msg = switch (response.statusCode) {
        402 => 'SimpleFIN subscription or payment required (HTTP 402).',
        403 => 'SimpleFIN access revoked or invalid (HTTP 403). Please re-link.',
        429 => 'SimpleFIN daily rate limit reached (HTTP 429). Try again later.',
        _ => 'SimpleFIN request failed (HTTP ${response.statusCode}).',
      };
      await _updateConnectionStatus(
        connectionPk,
        status: response.statusCode == 403 ? 'needs_reauth' : 'error',
        lastError: msg,
      );
      throw SimplefinException(msg, statusCode: response.statusCode);
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final errors = ((decoded['errors'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .toList();
    final accountsJson = (decoded['accounts'] as List<dynamic>?) ?? [];
    final accounts = accountsJson
        .whereType<Map<String, dynamic>>()
        .map(SimplefinAccountData.fromJson)
        .toList();

    await _updateConnectionStatus(
      connectionPk,
      status: errors.isNotEmpty ? 'warning' : 'active',
      lastError: errors.isNotEmpty ? errors.join('; ') : null,
    );

    return SimplefinAccountsResponse(errors: errors, accounts: accounts);
  }

  /// Removes the connection and its stored Access URL without deleting Wallets
  /// or historical Transactions.
  Future<void> deleteConnection(String connectionPk) async {
    final connection = await (db.select(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .getSingleOrNull();
    if (connection == null) return;

    await (db.update(db.wallets)
          ..where((t) => t.simplefinConnectionFk.equals(connectionPk)))
        .write(
      const WalletsCompanion(
        simplefinConnectionFk: Value(null),
        simplefinAccountId: Value(null),
        simplefinSyncStartDate: Value(null),
        simplefinLastSynced: Value(null),
        simplefinBalance: Value(null),
        simplefinBalanceDate: Value(null),
        simplefinError: Value(null),
      ),
    );

    await _secretStore.delete(connection.secureStorageKey);
    await (db.delete(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .go();
  }

  /// Links a SimpleFIN external account 1:1 to an existing Cashew Wallet,
  /// enforcing matching ISO currency codes.
  Future<TransactionWallet> linkAccountToExistingWallet({
    required String connectionPk,
    required SimplefinAccountData account,
    required String walletPk,
    DateTime? startDate,
  }) async {
    final wallet = await (db.select(db.wallets)
          ..where((t) => t.walletPk.equals(walletPk)))
        .getSingleOrNull();
    if (wallet == null) {
      throw SimplefinException('Target Wallet not found.');
    }

    final walletCurrency = (wallet.currency ?? 'usd').toUpperCase();
    final accountCurrency = account.currency.toUpperCase();
    if (walletCurrency != accountCurrency) {
      throw SimplefinException(
        'Currency mismatch: Wallet is $walletCurrency but SimpleFIN account is $accountCurrency.',
      );
    }

    // Enforce 1:1 mapping by unlinking any other Wallet previously bound to this external account.
    await (db.update(db.wallets)
          ..where((t) =>
              t.simplefinConnectionFk.equals(connectionPk) &
              t.simplefinAccountId.equals(account.id)))
        .write(
      const WalletsCompanion(
        simplefinConnectionFk: Value(null),
        simplefinAccountId: Value(null),
      ),
    );

    final now = DateTime.now();
    final effectiveStartDate =
        startDate ?? DateTime(now.year, now.month, now.day);

    await (db.update(db.wallets)..where((t) => t.walletPk.equals(walletPk)))
        .write(
      WalletsCompanion(
        simplefinConnectionFk: Value(connectionPk),
        simplefinAccountId: Value(account.id),
        simplefinSyncStartDate: Value(effectiveStartDate),
      ),
    );

    return (db.select(db.wallets)..where((t) => t.walletPk.equals(walletPk)))
        .getSingle();
  }

  /// Creates a new Cashew Wallet for a SimpleFIN external account,
  /// defaulting the initial sync start date to 30 days ago.
  Future<TransactionWallet> createWalletForAccount({
    required String connectionPk,
    required SimplefinAccountData account,
    DateTime? startDate,
  }) async {
    final existingWallets = await db.select(db.wallets).get();
    final nextOrder = existingWallets.isEmpty
        ? 0
        : existingWallets
                .map((w) => w.order)
                .reduce((a, b) => a > b ? a : b) +
            1;

    final now = DateTime.now();
    final effectiveStartDate =
        startDate ?? now.subtract(const Duration(days: 30));
    final newWalletPk = const Uuid().v4();

    await db.into(db.wallets).insert(
          WalletsCompanion.insert(
            walletPk: Value(newWalletPk),
            name: account.name,
            currency: Value(account.currency.toLowerCase()),
            order: nextOrder,
            simplefinConnectionFk: Value(connectionPk),
            simplefinAccountId: Value(account.id),
            simplefinSyncStartDate: Value(effectiveStartDate),
          ),
        );

    return (db.select(db.wallets)..where((t) => t.walletPk.equals(newWalletPk)))
        .getSingle();
  }

  /// Syncs settled transactions and bank balances for all Wallets linked to
  /// [connectionPk], deduplicating by SimpleFIN transaction ID.
  Future<SimplefinSyncResult> syncConnection(
    String connectionPk, {
    bool force = false,
  }) async {
    final connection = await (db.select(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .getSingleOrNull();
    if (connection == null) {
      throw SimplefinException('SimpleFIN connection not found.');
    }

    if (!force && connection.lastSynced != null) {
      final elapsed = DateTime.now().difference(connection.lastSynced!);
      if (elapsed < const Duration(hours: 4)) {
        return SimplefinSyncResult(throttled: true);
      }
    }

    final linkedWallets = await (db.select(db.wallets)
          ..where((t) => t.simplefinConnectionFk.equals(connectionPk)))
        .get();

    if (linkedWallets.isEmpty) {
      return SimplefinSyncResult();
    }

    DateTime? earliestStart;
    for (final wallet in linkedWallets) {
      final candidate = wallet.simplefinLastSynced != null
          ? wallet.simplefinLastSynced!.subtract(const Duration(days: 3))
          : wallet.simplefinSyncStartDate;
      if (candidate != null &&
          (earliestStart == null || candidate.isBefore(earliestStart))) {
        earliestStart = candidate;
      }
    }

    final response =
        await fetchAccounts(connectionPk, startDate: earliestStart);
    final accountsById = {for (final a in response.accounts) a.id: a};

    int imported = 0;
    int skippedPending = 0;
    int skippedDuplicate = 0;
    final now = DateTime.now();

    final pendingInsert = <(TransactionWallet, SimplefinTransactionData, String?)>[];
    final unmatchedDescriptions = <String>{};

    for (final wallet in linkedWallets) {
      final account = accountsById[wallet.simplefinAccountId];
      final accountName = account?.name ?? wallet.name;
      final accountId = account?.id ?? wallet.simplefinAccountId ?? '';

      final matchingErrors = response.errors
          .where((e) =>
              e.toLowerCase().contains(accountName.toLowerCase()) ||
              (accountId.isNotEmpty && e.contains(accountId)))
          .toList();
      final walletError = matchingErrors.isNotEmpty
          ? matchingErrors.join('; ')
          : null;

      if (account == null) {
        if (walletError != null) {
          await (db.update(db.wallets)
                ..where((t) => t.walletPk.equals(wallet.walletPk)))
              .write(WalletsCompanion(simplefinError: Value(walletError)));
        }
        continue;
      }

      await (db.update(db.wallets)
            ..where((t) => t.walletPk.equals(wallet.walletPk)))
          .write(
        WalletsCompanion(
          simplefinBalance: Value(account.balance),
          simplefinBalanceDate: Value(account.balanceDate ?? now),
          simplefinLastSynced: Value(now),
          simplefinError: Value(walletError),
        ),
      );

      for (final tx in account.transactions) {
        if (tx.pending) {
          skippedPending++;
          continue;
        }
        if (wallet.simplefinSyncStartDate != null &&
            tx.posted.isBefore(wallet.simplefinSyncStartDate!)) {
          continue;
        }

        final existing = await (db.select(db.transactions)
              ..where((t) => t.simplefinTransactionId.equals(tx.id)))
            .getSingleOrNull();
        if (existing != null) {
          skippedDuplicate++;
          continue;
        }

        final localCategoryFk = await _matchAssociatedTitle(tx.description);
        if (localCategoryFk == null) {
          unmatchedDescriptions.add(tx.description);
        }
        pendingInsert.add((wallet, tx, localCategoryFk));
      }
    }

    Map<String, String> aiCategoryMap = {};
    if (unmatchedDescriptions.isNotEmpty) {
      aiCategoryMap =
          await _categorizeBatchWithAi(unmatchedDescriptions.toList());
    }

    for (final (wallet, tx, localCategoryFk) in pendingInsert) {
      final categoryFk = localCategoryFk ??
          aiCategoryMap[tx.description] ??
          await _getOrCreateUnknownCategory();
      final txPk = const Uuid().v4();

      await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              transactionPk: Value(txPk),
              name: tx.description,
              amount: tx.amount,
              note: tx.memo,
              categoryFk: categoryFk,
              walletFk: Value(wallet.walletPk),
              dateCreated: Value(tx.posted),
              income: Value(tx.amount > 0),
              paid: const Value(true),
              methodAdded: const Value(MethodAdded.simplefin),
              simplefinTransactionId: Value(tx.id),
              simplefinUnreviewed: const Value(true),
            ),
          );
      imported++;
    }

    await (db.update(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .write(SimplefinConnectionsCompanion(lastSynced: Value(now)));

    return SimplefinSyncResult(
      importedCount: imported,
      skippedPendingCount: skippedPending,
      skippedDuplicateCount: skippedDuplicate,
      errors: response.errors,
    );
  }

  /// Stores opt-in BYOK AI categorization settings in secure storage.
  Future<void> configureAiCategorization({
    required SimplefinAiProvider provider,
    required String apiKey,
    String? endpointUrl,
    String? model,
  }) async {
    await _secretStore.write('simplefin_ai_provider', provider.name);
    await _secretStore.write('simplefin_ai_api_key', apiKey.trim());
    if (endpointUrl != null && endpointUrl.trim().isNotEmpty) {
      await _secretStore.write('simplefin_ai_endpoint', endpointUrl.trim());
    } else {
      await _secretStore.delete('simplefin_ai_endpoint');
    }
    if (model != null && model.trim().isNotEmpty) {
      await _secretStore.write('simplefin_ai_model', model.trim());
    } else {
      await _secretStore.delete('simplefin_ai_model');
    }
  }

  /// Reads the current BYOK AI categorization configuration.
  Future<SimplefinAiConfig> getAiConfig() async {
    final providerName = await _secretStore.read('simplefin_ai_provider');
    final provider = SimplefinAiProvider.values.firstWhere(
      (p) => p.name == providerName,
      orElse: () => SimplefinAiProvider.none,
    );
    return SimplefinAiConfig(
      provider: provider,
      apiKey: await _secretStore.read('simplefin_ai_api_key'),
      endpointUrl: await _secretStore.read('simplefin_ai_endpoint'),
      model: await _secretStore.read('simplefin_ai_model'),
    );
  }

  Future<String?> _matchAssociatedTitle(String description) async {
    final matches =
        await db.getSimilarAssociatedTitles(title: description, limit: 1);
    if (matches.isNotEmpty) {
      return matches.first.category.categoryPk;
    }

    final lowerDesc = description.toLowerCase();
    final allTitles = await (db.select(db.associatedTitles)
          ..orderBy([(t) => OrderingTerm.desc(t.order)]))
        .get();
    for (final rule in allTitles) {
      final pattern = rule.title.trim().toLowerCase();
      if (pattern.isNotEmpty && lowerDesc.contains(pattern)) {
        return rule.categoryFk;
      }
    }

    return null;
  }

  Future<Map<String, String>> _categorizeBatchWithAi(
    List<String> descriptions,
  ) async {
    try {
      final config = await getAiConfig();
      if (config.provider == SimplefinAiProvider.none ||
          config.apiKey == null ||
          config.apiKey!.isEmpty) {
        return {};
      }

      final allCategories = await db.select(db.categories).get();
      final categories =
          allCategories.where((c) => c.categoryPk != '0').toList();
      if (categories.isEmpty) return {};

      final catByLowerName = {
        for (final c in categories) c.name.trim().toLowerCase(): c.categoryPk,
      };
      final categoryNames = categories.map((c) => c.name).toList();
      final prompt =
          'Map each transaction description to one category from this list: '
          '${jsonEncode(categoryNames)}. '
          'Return ONLY a JSON object mapping description to category name. '
          'Descriptions: ${jsonEncode(descriptions)}';

      final String? rawContent;
      if (config.provider == SimplefinAiProvider.gemini) {
        final model = config.model ?? 'gemini-1.5-flash';
        final uri = Uri.parse(
          config.endpointUrl ??
              'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${config.apiKey}',
        );
        final res = await _httpClient.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ]
          }),
        );
        if (res.statusCode != 200) return {};
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        rawContent = decoded['candidates']?[0]?['content']?['parts']?[0]
                ?['text']
            ?.toString();
      } else {
        final uri = Uri.parse(
          config.endpointUrl ?? 'https://api.openai.com/v1/chat/completions',
        );
        final res = await _httpClient.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${config.apiKey}',
          },
          body: jsonEncode({
            'model': config.model ?? 'gpt-4o-mini',
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'response_format': {'type': 'json_object'},
          }),
        );
        if (res.statusCode != 200) return {};
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        rawContent =
            decoded['choices']?[0]?['message']?['content']?.toString();
      }

      if (rawContent == null || rawContent.isEmpty) return {};
      final cleaned = rawContent
          .replaceAll(RegExp(r'^```json\s*|\s*```$'), '')
          .trim();
      final parsed = jsonDecode(cleaned);
      if (parsed is! Map<String, dynamic>) return {};

      final result = <String, String>{};
      for (final entry in parsed.entries) {
        final matchedPk =
            catByLowerName[entry.value.toString().trim().toLowerCase()];
        if (matchedPk != null) {
          result[entry.key] = matchedPk;
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<String> _getOrCreateUnknownCategory() async {
    final existing = await (db.select(db.categories)
          ..where((c) => c.name.lower().equals('unknown')))
        .get();
    if (existing.isNotEmpty) {
      return existing.first.categoryPk;
    }

    final allCats = await db.select(db.categories).get();
    final nextOrder = allCats.isEmpty
        ? 0
        : allCats.map((c) => c.order).reduce((a, b) => a > b ? a : b) + 1;
    final pk = const Uuid().v4();
    await db.into(db.categories).insert(
          CategoriesCompanion.insert(
            categoryPk: Value(pk),
            name: 'Unknown',
            order: nextOrder,
            income: const Value(false),
            methodAdded: const Value(MethodAdded.simplefin),
          ),
        );
    return pk;
  }

  /// Returns all Synced Transactions currently flagged as unreviewed.
  Future<List<Transaction>> getUnreviewedTransactions() {
    return (db.select(db.transactions)
          ..where((t) => t.simplefinUnreviewed.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(t.dateCreated)]))
        .get();
  }

  static Stream<int> watchUnreviewedTransactionCount(FinanceDatabase db) {
    return (db.select(db.transactions)
          ..where((t) => t.simplefinUnreviewed.equals(true)))
        .watch()
        .map((rows) => rows.length);
  }

  /// Marks an Unreviewed Transaction as reviewed without altering its category
  /// or amount.
  Future<void> confirmTransactionReviewed(String transactionPk) async {
    await (db.update(db.transactions)
          ..where((t) => t.transactionPk.equals(transactionPk)))
        .write(const TransactionsCompanion(simplefinUnreviewed: Value(false)));
  }

  /// Recategorizes an Unreviewed Transaction, clears its unreviewed flag, and
  /// saves or updates an AssociatedTitle rule so future syncs match locally.
  Future<void> recategorizeAndLearn(
    String transactionPk,
    String newCategoryPk,
  ) async {
    final tx = await (db.select(db.transactions)
          ..where((t) => t.transactionPk.equals(transactionPk)))
        .getSingleOrNull();
    if (tx == null) return;

    await (db.update(db.transactions)
          ..where((t) => t.transactionPk.equals(transactionPk)))
        .write(
      TransactionsCompanion(
        categoryFk: Value(newCategoryPk),
        simplefinUnreviewed: const Value(false),
      ),
    );

    final merchantTitle = tx.name.trim();
    if (merchantTitle.isEmpty) return;

    final existingRule = await (db.select(db.associatedTitles)
          ..where((a) => a.title.lower().equals(merchantTitle.toLowerCase())))
        .getSingleOrNull();

    if (existingRule != null) {
      await (db.update(db.associatedTitles)
            ..where(
                (a) => a.associatedTitlePk.equals(existingRule.associatedTitlePk)))
          .write(AssociatedTitlesCompanion(categoryFk: Value(newCategoryPk)));
    } else {
      final allTitles = await db.select(db.associatedTitles).get();
      final nextOrder = allTitles.isEmpty
          ? 0
          : allTitles.map((a) => a.order).reduce((a, b) => a > b ? a : b) + 1;
      await db.into(db.associatedTitles).insert(
            AssociatedTitlesCompanion.insert(
              title: merchantTitle,
              categoryFk: newCategoryPk,
              order: nextOrder,
            ),
          );
    }
  }

  /// Computes the sum of paid transactions in a Wallet.
  Future<double> getWalletLedgerBalance(String walletPk) async {
    final txs = await (db.select(db.transactions)
          ..where((t) => t.walletFk.equals(walletPk) & t.paid.equals(true)))
        .get();
    var sum = 0.0;
    for (final t in txs) {
      sum += t.amount;
    }
    return sum;
  }

  /// Inserts a Balance Correction transaction (categoryFk = "0") for the exact
  /// delta between the bank's reported SimpleFIN balance and Cashew's ledger.
  /// Returns null when already balanced within 0.005.
  Future<Transaction?> reconcileWalletBalance(String walletPk) async {
    final wallet = await (db.select(db.wallets)
          ..where((t) => t.walletPk.equals(walletPk)))
        .getSingleOrNull();
    if (wallet == null || wallet.simplefinBalance == null) return null;

    final ledgerSum = await getWalletLedgerBalance(walletPk);
    final delta = double.parse(
        (wallet.simplefinBalance! - ledgerSum).toStringAsFixed(2));
    if (delta.abs() < 0.005) return null;

    // Ensure Balance Correction category ("0") exists.
    final balCat = await (db.select(db.categories)
          ..where((c) => c.categoryPk.equals('0')))
        .getSingleOrNull();
    if (balCat == null) {
      await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              categoryPk: const Value('0'),
              name: 'Balance Correction',
              order: 0,
              income: const Value(false),
            ),
          );
    }

    final txPk = const Uuid().v4();
    await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            transactionPk: Value(txPk),
            name: 'Balance Correction',
            amount: delta,
            note: 'SimpleFIN balance reconciliation',
            categoryFk: '0',
            walletFk: Value(walletPk),
            dateCreated: Value(DateTime.now()),
            income: Value(delta > 0),
            paid: const Value(true),
            methodAdded: const Value(MethodAdded.simplefin),
          ),
        );

    return (db.select(db.transactions)
          ..where((t) => t.transactionPk.equals(txPk)))
        .getSingle();
  }

  /// Syncs all configured SimpleFIN connections that have not synced within
  /// the 4-hour launch throttle, isolating per-connection errors.
  Future<Map<String, SimplefinSyncResult>> syncAllDueConnections() async {
    final connections = await getConnections();
    final results = <String, SimplefinSyncResult>{};
    for (final conn in connections) {
      try {
        results[conn.connectionPk] =
            await syncConnection(conn.connectionPk, force: false);
      } catch (e) {
        results[conn.connectionPk] =
            SimplefinSyncResult(errors: [e.toString()]);
      }
    }
    return results;
  }

  Future<void> _updateConnectionStatus(
    String connectionPk, {
    required String status,
    String? lastError,
  }) async {
    await (db.update(db.simplefinConnections)
          ..where((t) => t.connectionPk.equals(connectionPk)))
        .write(
      SimplefinConnectionsCompanion(
        status: Value(status),
        lastError: Value(lastError),
      ),
    );
  }
}
