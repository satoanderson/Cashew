# 04: Review queue for Unreviewed Transactions with AssociatedTitles learning

**What to build:** A banner and dedicated review list (modeled on Cashew's existing auto-transactions mailbox) surface recent Unreviewed Transactions so the user can confirm them with one tap or recategorize them, automatically saving category corrections into `AssociatedTitles` for future syncs.

**Blocked by:** 03: Manual Sync Now for settled Synced Transactions with deduplication

**Status:** resolved

- [x] A banner/entry point displays the count of Unreviewed Transactions and opens the review queue.
- [x] Confirming an Unreviewed Transaction clears its unreviewed flag without changing budget totals.
- [x] Recategorizing an Unreviewed Transaction updates its category, clears its unreviewed flag, and creates or updates an `AssociatedTitle` mapping for that merchant description.
- [x] In-memory Drift tests verify that confirming clears the unreviewed flag and recategorizing causes a subsequent sync with the same merchant to match locally via `AssociatedTitles`.
