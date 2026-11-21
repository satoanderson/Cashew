import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/simplefinReviewPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/simplefinService.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';

/// Settings page for managing SimpleFIN Bridge connections and inspecting
/// external bank accounts.
class SimplefinSettingsPage extends StatefulWidget {
  const SimplefinSettingsPage({Key? key}) : super(key: key);

  @override
  State<SimplefinSettingsPage> createState() => _SimplefinSettingsPageState();
}

class _SimplefinSettingsPageState extends State<SimplefinSettingsPage> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _aiKeyController = TextEditingController();
  final TextEditingController _aiEndpointController = TextEditingController();
  final TextEditingController _aiModelController = TextEditingController();
  late final SimplefinService _service;

  List<SimplefinConnection> _connections = [];
  List<TransactionWallet> _wallets = [];
  final Map<String, double> _ledgerBalances = {};
  int _unreviewedCount = 0;
  SimplefinAiProvider _aiProvider = SimplefinAiProvider.none;
  final Map<String, SimplefinAccountsResponse> _accountsByConnection = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _service = SimplefinService(db: database);
    _loadConnections();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _labelController.dispose();
    _aiKeyController.dispose();
    _aiEndpointController.dispose();
    _aiModelController.dispose();
    super.dispose();
  }

  Future<void> _loadConnections() async {
    final list = await _service.getConnections();
    final wallets = await database.select(database.wallets).get();
    final unreviewed = await _service.getUnreviewedTransactions();
    final aiConfig = await _service.getAiConfig();
    final ledgerMap = <String, double>{};
    for (final w in wallets) {
      if (w.simplefinConnectionFk != null) {
        ledgerMap[w.walletPk] = await _service.getWalletLedgerBalance(w.walletPk);
      }
    }
    if (!mounted) return;
    setState(() {
      _connections = list;
      _wallets = wallets;
      _ledgerBalances
        ..clear()
        ..addAll(ledgerMap);
      _unreviewedCount = unreviewed.length;
      _aiProvider = aiConfig.provider;
      _aiKeyController.text = aiConfig.apiKey ?? '';
      _aiEndpointController.text = aiConfig.endpointUrl ?? '';
      _aiModelController.text = aiConfig.model ?? '';
    });
  }

  Future<void> _claimToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      openSnackbar(SnackbarMessage(title: 'Enter a SimpleFIN setup token'));
      return;
    }

    setState(() => _loading = true);
    try {
      final connection = await _service.claimSetupToken(
        token,
        label: _labelController.text.trim(),
      );
      _tokenController.clear();
      _labelController.clear();
      await _loadConnections();
      await _loadAccounts(connection.connectionPk);
      openSnackbar(SnackbarMessage(title: 'SimpleFIN connected'));
    } catch (e) {
      openSnackbar(SnackbarMessage(title: e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadAccounts(String connectionPk) async {
    setState(() => _loading = true);
    try {
      final response = await _service.fetchAccounts(connectionPk);
      if (!mounted) return;
      setState(() {
        _accountsByConnection[connectionPk] = response;
      });
      await _loadConnections();
    } catch (e) {
      openSnackbar(SnackbarMessage(title: e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteConnection(String connectionPk) async {
    await _service.deleteConnection(connectionPk);
    _accountsByConnection.remove(connectionPk);
    await _loadConnections();
    openSnackbar(SnackbarMessage(title: 'SimpleFIN connection removed'));
  }

  Future<void> _syncNow(String connectionPk) async {
    setState(() => _loading = true);
    try {
      final result = await _service.syncConnection(connectionPk, force: true);
      await _loadConnections();
      openSnackbar(
        SnackbarMessage(
          title:
              'Synced: ${result.importedCount} imported, ${result.skippedDuplicateCount} duplicates',
        ),
      );
    } catch (e) {
      openSnackbar(SnackbarMessage(title: e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showLinkDialog(
    String connectionPk,
    SimplefinAccountData account,
  ) async {
    String? selectedWalletPk;
    DateTime startDate = DateTime.now().subtract(const Duration(days: 30));

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isNew = selectedWalletPk == null;
          return AlertDialog(
            title: Text('Map ${account.name} (${account.currency})'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String?>(
                  value: selectedWalletPk,
                  decoration: const InputDecoration(labelText: 'Target Account'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Create new Account'),
                    ),
                    ..._wallets.map(
                      (w) => DropdownMenuItem<String?>(
                        value: w.walletPk,
                        child: Text(
                          '${w.name} (${(w.currency ?? "usd").toUpperCase()})',
                        ),
                      ),
                    ),
                  ],
                  onChanged: (val) {
                    setDialogState(() {
                      selectedWalletPk = val;
                      final now = DateTime.now();
                      startDate = val == null
                          ? now.subtract(const Duration(days: 30))
                          : DateTime(now.year, now.month, now.day);
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(
                    'Start sync from: ${startDate.toLocal().toString().split(" ").first}'
                    '${isNew ? " (30d default)" : " (Today default)"}',
                  ),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: startDate,
                      firstDate: DateTime(2015),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setDialogState(() => startDate = picked);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  try {
                    if (selectedWalletPk == null) {
                      await _service.createWalletForAccount(
                        connectionPk: connectionPk,
                        account: account,
                        startDate: startDate,
                      );
                    } else {
                      await _service.linkAccountToExistingWallet(
                        connectionPk: connectionPk,
                        account: account,
                        walletPk: selectedWalletPk!,
                        startDate: startDate,
                      );
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    await _loadConnections();
                    openSnackbar(
                      SnackbarMessage(title: 'Account linked to ${account.name}'),
                    );
                  } catch (e) {
                    openSnackbar(SnackbarMessage(title: e.toString()));
                  }
                },
                child: const Text('Save Mapping'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: 'SimpleFIN Bank Sync',
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              if (_unreviewedCount > 0)
                Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: ListTile(
                    leading: const Icon(Icons.rate_review_outlined),
                    title: Text('$_unreviewedCount transactions to review'),
                    subtitle: const Text('Tap to confirm or recategorize'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await pushRoute(context, const SimplefinReviewPage());
                      await _loadConnections();
                    },
                  ),
                ),
              const TextFont(
                text: 'Add SimpleFIN Connection',
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: 'Connection Label (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'SimpleFIN Setup Token',
                  border: OutlineInputBorder(),
                ),
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: 12),
              Button(
                label: _loading ? 'Working...' : 'Connect SimpleFIN',
                onTap: _loading ? () {} : _claimToken,
              ),
              const SizedBox(height: 24),
              const TextFont(
                text: 'Connections',
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              const SizedBox(height: 8),
              if (_connections.isEmpty)
                const TextFont(
                  text: 'No SimpleFIN connections yet.',
                  fontSize: 14,
                ),
              for (final conn in _connections)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: TextFont(
                                text: '${conn.label} (${conn.status})',
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Sync Now',
                              icon: const Icon(Icons.sync),
                              onPressed: _loading
                                  ? null
                                  : () => _syncNow(conn.connectionPk),
                            ),
                            IconButton(
                              tooltip: 'Refresh Accounts',
                              icon: const Icon(Icons.refresh),
                              onPressed: _loading
                                  ? null
                                  : () => _loadAccounts(conn.connectionPk),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _loading
                                  ? null
                                  : () => _deleteConnection(conn.connectionPk),
                            ),
                          ],
                        ),
                        if (conn.lastError != null &&
                            conn.lastError!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: TextFont(
                              text: conn.lastError!,
                              fontSize: 13,
                              textColor: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ..._wallets
                            .where(
                                (w) => w.simplefinConnectionFk == conn.connectionPk)
                            .map((w) {
                          final ledger = _ledgerBalances[w.walletPk] ?? 0.0;
                          final bank = w.simplefinBalance;
                          final hasDiff = bank != null && (bank - ledger).abs() >= 0.005;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: w.simplefinError != null
                                ? Icon(
                                    Icons.warning_amber_rounded,
                                    color: Theme.of(context).colorScheme.error,
                                  )
                                : const Icon(Icons.account_balance_wallet_outlined),
                            title: Text(w.name),
                            subtitle: Text(
                              w.simplefinError != null
                                  ? '${w.simplefinError!} • Re-link or check 2FA'
                                  : bank != null
                                      ? 'Bank: ${bank.toStringAsFixed(2)} • Ledger: ${ledger.toStringAsFixed(2)}'
                                      : 'Linked • Not yet synced',
                            ),
                            trailing: hasDiff
                                ? TextButton(
                                    onPressed: () async {
                                      await _service
                                          .reconcileWalletBalance(w.walletPk);
                                      await _loadConnections();
                                      openSnackbar(
                                        SnackbarMessage(
                                          title: 'Balance reconciled',
                                        ),
                                      );
                                    },
                                    child: const Text('Reconcile'),
                                  )
                                : null,
                          );
                        }),
                        if (_accountsByConnection[conn.connectionPk] != null)
                          ..._accountsByConnection[conn.connectionPk]!
                              .accounts
                              .map(
                            (acc) {
                              final linkedWallet = _wallets
                                  .where((w) =>
                                      w.simplefinConnectionFk ==
                                          conn.connectionPk &&
                                      w.simplefinAccountId == acc.id)
                                  .firstOrNull;
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(acc.name),
                                subtitle: Text(
                                  linkedWallet != null
                                      ? '${acc.currency} • Linked to ${linkedWallet.name}'
                                      : '${acc.currency} • Not linked',
                                ),
                                trailing: TextButton(
                                  onPressed: () =>
                                      _showLinkDialog(conn.connectionPk, acc),
                                  child: Text(
                                    linkedWallet != null
                                        ? acc.balance.toStringAsFixed(2)
                                        : 'Link Account',
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              const TextFont(
                text: 'AI Categorization Fallback (Optional)',
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<SimplefinAiProvider>(
                value: _aiProvider,
                decoration: const InputDecoration(
                  labelText: 'AI Provider',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: SimplefinAiProvider.none,
                    child: Text('Disabled (Unknown fallback)'),
                  ),
                  DropdownMenuItem(
                    value: SimplefinAiProvider.gemini,
                    child: Text('Google Gemini (BYOK)'),
                  ),
                  DropdownMenuItem(
                    value: SimplefinAiProvider.openAiCompatible,
                    child: Text('OpenAI-Compatible (BYOK)'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _aiProvider = val);
                },
              ),
              if (_aiProvider != SimplefinAiProvider.none) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _aiKeyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _aiEndpointController,
                  decoration: const InputDecoration(
                    labelText: 'Custom Endpoint URL (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _aiModelController,
                  decoration: const InputDecoration(
                    labelText: 'AI Model (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Button(
                label: 'Save AI Settings',
                onTap: () async {
                  await _service.configureAiCategorization(
                    provider: _aiProvider,
                    apiKey: _aiKeyController.text,
                    endpointUrl: _aiEndpointController.text,
                    model: _aiModelController.text,
                  );
                  openSnackbar(SnackbarMessage(title: 'AI settings saved'));
                },
              ),
            ]),
          ),
        ),
      ],
    );
  }
}
