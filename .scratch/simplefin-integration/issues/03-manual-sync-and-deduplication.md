# 03: Manual Sync Now for settled Synced Transactions with deduplication

**What to build:** A user can tap "Sync Now" to fetch settled (`pending == false`) transactions from SimpleFIN, skip pending entries, categorize via `AssociatedTitles` (falling back to "Unknown"), deduplicate using SimpleFIN's transaction ID, and insert them immediately into active budgets as Unreviewed Transactions.

**Blocked by:** 02: Map SimpleFIN accounts 1:1 to Wallets with currency validation

**Status:** resolved

- [x] Transaction schema stores an indexed external SimpleFIN transaction ID, an unreviewed boolean flag, and `MethodAdded.simplefin`.
- [x] Sync skips transactions where `pending` is true and only imports settled transactions.
- [x] Repeated syncs are idempotent: existing external transaction IDs are never duplicated.
- [x] Unmatched descriptions fall back to a default "Unknown" category after checking `AssociatedTitles`.
- [x] Inserted Synced Transactions are marked as Unreviewed Transactions and immediately count toward active budgets and Wallet totals.
- [x] Sync service tests with mocked SimpleFIN HTTP + in-memory Drift verify settled filtering, deduplication, `AssociatedTitles` matching, and Unknown fallback.
