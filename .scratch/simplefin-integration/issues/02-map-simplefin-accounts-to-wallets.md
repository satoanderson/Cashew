# 02: Map SimpleFIN accounts 1:1 to Wallets with currency validation

**What to build:** From a SimpleFIN Connection's external account list, a user can map each external account 1:1 to an existing Cashew Wallet (enforcing matching ISO currency codes) or auto-create a new Wallet with that account's name and currency, and select the initial sync start date.

**Blocked by:** 01: Claim SimpleFIN Setup Token and list external accounts

**Status:** resolved

- [x] Wallet schema stores optional SimpleFIN linkage metadata (connection ID, external account ID, last sync timestamp).
- [x] User can link a SimpleFIN account to an existing Wallet when ISO currency codes match, and receives a clear validation error on mismatch.
- [x] User can create a new Wallet directly from a SimpleFIN account with its name and ISO currency auto-populated.
- [x] Initial sync `start-date` defaults to Today when linking an existing Wallet and Last 30 days when creating a new Wallet, with a date picker override.
- [x] In-memory Drift tests verify 1:1 mapping, currency mismatch rejection, and default start-date selection.
