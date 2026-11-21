import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/simplefinService.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';

/// Review queue for recently synced Unreviewed Transactions.
class SimplefinReviewPage extends StatefulWidget {
  const SimplefinReviewPage({Key? key}) : super(key: key);

  @override
  State<SimplefinReviewPage> createState() => _SimplefinReviewPageState();
}

class _SimplefinReviewPageState extends State<SimplefinReviewPage> {
  late final SimplefinService _service;
  List<Transaction> _unreviewed = [];
  List<TransactionCategory> _categories = [];

  @override
  void initState() {
    super.initState();
    _service = SimplefinService(db: database);
    _load();
  }

  Future<void> _load() async {
    final txs = await _service.getUnreviewedTransactions();
    final cats = await database.select(database.categories).get();
    if (!mounted) return;
    setState(() {
      _unreviewed = txs;
      _categories = cats;
    });
  }

  Future<void> _confirm(String transactionPk) async {
    await _service.confirmTransactionReviewed(transactionPk);
    await _load();
    openSnackbar(SnackbarMessage(title: 'Transaction reviewed'));
  }

  Future<void> _recategorize(Transaction tx) async {
    String selectedCategoryPk = tx.categoryFk;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Categorize "${tx.name}"'),
          content: DropdownButtonFormField<String>(
            value: _categories.any((c) => c.categoryPk == selectedCategoryPk)
                ? selectedCategoryPk
                : null,
            items: _categories
                .map(
                  (c) => DropdownMenuItem(
                    value: c.categoryPk,
                    child: Text(c.name),
                  ),
                )
                .toList(),
            onChanged: (val) {
              if (val != null) {
                setDialogState(() => selectedCategoryPk = val);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                await _service.recategorizeAndLearn(
                  tx.transactionPk,
                  selectedCategoryPk,
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
                await _load();
                openSnackbar(
                  SnackbarMessage(title: 'Updated and saved rule'),
                );
              },
              child: const Text('Save & Learn'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final catNames = {
      for (final c in _categories) c.categoryPk: c.name,
    };

    return PageFramework(
      title: 'Review Synced Transactions',
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: _unreviewed.isEmpty
              ? const SliverToBoxAdapter(
                  child: TextFont(
                    text: 'All synced transactions have been reviewed.',
                    fontSize: 15,
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final tx = _unreviewed[index];
                      final catName = catNames[tx.categoryFk] ?? 'Unknown';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          title: Text(tx.name),
                          subtitle: Text(
                            '$catName • ${tx.dateCreated.toLocal().toString().split(" ").first}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tx.amount.toStringAsFixed(2),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Recategorize',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _recategorize(tx),
                              ),
                              IconButton(
                                tooltip: 'Confirm Reviewed',
                                icon: const Icon(Icons.check_circle_outline),
                                onPressed: () => _confirm(tx.transactionPk),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    childCount: _unreviewed.length,
                  ),
                ),
        ),
      ],
    );
  }
}
