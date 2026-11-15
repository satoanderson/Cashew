# 05: Bank balance display, discrepancy reconciliation, and error badges

**What to build:** Synced Wallets store and display the bank's reported balance alongside Cashew's ledger balance, offer a one-tap Balance Correction for the exact delta when they diverge, and display non-blocking warning badges with a re-link prompt when SimpleFIN reports connection or 2FA errors.

**Blocked by:** 03: Manual Sync Now for settled Synced Transactions with deduplication

**Status:** resolved

- [x] Wallet schema stores the last reported bank balance, balance date, and last sync error message.
- [x] Linked Wallet cards display the official bank balance alongside Cashew's calculated ledger balance.
- [x] When bank balance differs from the ledger balance, a one-tap action inserts a Balance Correction transaction for the exact delta.
- [x] SimpleFIN account-level errors (such as expired 2FA) attach a non-blocking warning badge to the affected Wallet while healthy accounts in the same connection still sync.
- [x] Tests verify exact delta calculation on Balance Correction and partial error isolation across multiple accounts.
