Status: ready-for-agent

# SimpleFIN Banking Integration

## Problem Statement

Cashew users currently have to log expenses manually or rely on CSV imports and Android notification/email parsing to keep their Wallets and budgets up to date. Manual entry is tedious and easy to fall behind on, causing budgets and account balances to drift from real bank activity. Users want automated bank transaction and balance tracking similar to apps like Buddy, while keeping Cashew's local-first privacy model.

## Solution

Integrate SimpleFIN Bridge directly into Cashew on Mobile and Desktop so users can link external bank accounts to Cashew Wallets. On app launch (throttled) or on demand, Cashew fetches settled transactions and current bank balances directly from SimpleFIN, categorizes transactions automatically (via local rules, optional user-configured AI, or an Unknown fallback), and inserts them straight into active budgets as Unreviewed Transactions. Users can then review, recategorize, and reconcile balances at their convenience without blocking budget updates.

## User Stories

1. As a Cashew user, I want to paste or scan a SimpleFIN Setup Token, so that I can establish a SimpleFIN Connection without running a third-party backend server.
2. As a Cashew user, I want my SimpleFIN Access URL stored securely on my device, so that my banking credentials remain private and local-first.
3. As a Cashew user, I want to see all external bank accounts returned by my SimpleFIN Connection during setup, so that I can choose which ones to track in Cashew.
4. As a Cashew user, I want to map each SimpleFIN bank account 1:1 to an existing Wallet, so that I can continue tracking an account that already has historical data.
5. As a Cashew user, I want to create a new Wallet automatically from a SimpleFIN bank account during setup, so that I do not have to configure it manually.
6. As a Cashew user, I want Cashew to enforce matching ISO currency codes when linking a SimpleFIN account to an existing Wallet, so that my balances and budget totals do not get corrupted by currency mismatches.
7. As a Cashew user, I want to choose the initial sync start date when linking an account (defaulting to Today for existing Wallets and Last 30 days for new Wallets), so that I avoid duplicating older manual transactions while still importing recent history for new Wallets.
8. As a Cashew user, I want Cashew to sync my SimpleFIN Connections automatically when I open the app (throttled to respect daily rate limits), so that my budgets stay current without manual effort.
9. As a Cashew user, I want a manual "Sync Now" button, so that I can pull the latest bank activity whenever I want.
10. As a Cashew user, I want Synced Transactions to enter my active budgets and Wallet totals immediately on import, so that my spending limits reflect real bank activity without waiting for manual approval.
11. As a Cashew user, I want Cashew to skip pending bank transactions until they are settled, so that temporary holds or changing amounts do not pollute my ledger.
12. As a Cashew user, I want Cashew to deduplicate Synced Transactions using their SimpleFIN transaction ID, so that repeated syncs never create duplicate entries.
13. As a Cashew user, I want newly imported transactions to be matched against my existing AssociatedTitles rules first, so that known merchants are categorized accurately and instantaneously on-device.
14. As a Cashew user, I want an optional "Bring Your Own Key" AI integration (supporting Gemini or OpenAI-compatible endpoints) as a fallback when AssociatedTitles has no match, so that unfamiliar merchants are categorized intelligently.
15. As a Cashew user, I want the AI fallback to send only merchant descriptions and my category names in a single batch per sync, so that my account numbers, balances, and credentials are never shared with an AI provider.
16. As a Cashew user, I want transactions to fall back to an "Unknown" category when both AssociatedTitles and AI cannot classify them (or when AI is disabled or offline), so that syncs never fail or block.
17. As a Cashew user, I want newly imported transactions to be flagged as Unreviewed Transactions, so that I know which entries I have not yet verified.
18. As a Cashew user, I want a dedicated review list and banner showing recent Unreviewed Transactions (modeled on Cashew's existing auto-transactions mailbox), so that I can quickly audit them in one place.
19. As a Cashew user, I want to confirm an Unreviewed Transaction with a single tap or edit its category and details, so that I can clear my review queue quickly.
20. As a Cashew user, I want Cashew to save my category corrections from review into AssociatedTitles automatically, so that future transactions from the same merchant categorize locally without needing AI.
21. As a Cashew user, I want to see the bank's reported balance alongside Cashew's calculated Wallet balance, so that I can verify my ledger matches my real bank account.
22. As a Cashew user, I want a one-tap option to create a Balance Correction transaction when the Wallet ledger diverges from the bank's reported balance, so that I can reconcile discrepancies easily.
23. As a Cashew user, I want to see a non-blocking warning badge on a Wallet if SimpleFIN reports a bank connection error or expired 2FA, so that I know when I need to re-link without losing access to my local data or blocking other healthy accounts.
24. As a Cashew user, I want SimpleFIN sync options to be hidden on Flutter Web, so that I am not confused by browser CORS failures.
25. As a Cashew user, I want to unlink or delete a SimpleFIN Connection without deleting my existing local Wallet or historical transactions, so that my financial history remains intact if I stop using bank sync.

## Implementation Decisions

- **Direct Client-to-SimpleFIN Architecture (ADR-0001)**: Cashew exchanges the user's SimpleFIN Setup Token directly from the device via HTTP POST to obtain the Access URL, storing it in platform secure storage (Flutter Secure Storage). Sync requests fetch the `/accounts` endpoint directly over HTTPS with HTTP Basic Auth. SimpleFIN features are gated off on Flutter Web to avoid browser CORS errors without requiring a proxy server.
- **Database Schema Extensions**:
  - Extend the Wallet model to store optional SimpleFIN linkage metadata (connection identifier, external account identifier, last reported bank balance, bank balance timestamp, last sync timestamp, and last sync error message).
  - Extend the Transaction model to store an optional external SimpleFIN transaction identifier (unique/indexed for deduplication), a boolean or enum flag indicating whether the entry is an Unreviewed Transaction, and a new `MethodAdded` variant for SimpleFIN.
  - Add a SimpleFIN Connections table (or metadata store) tracking connection label, status, last sync time, and secure-storage key reference.
- **Sync and Rate-Limit Policy**: Automatic sync runs on app launch only if at least 4 hours have elapsed since the previous sync for that connection, respecting SimpleFIN Bridge's daily request limits (~24 requests/day). Manual "Sync Now" triggers bypass the launch throttle while surfacing any HTTP 402/403/429 errors clearly.
- **Initial Sync Window**: When linking an account, the user selects a `start-date` epoch timestamp. Defaults to Today (start of day) when linking to an existing Wallet, and 30 days prior when creating a new Wallet. Subsequent syncs query from the last successful sync timestamp (with a small overlap window, relying on SimpleFIN ID deduplication to catch delayed postings).
- **Categorization Pipeline**:
  1. Query local `AssociatedTitles` for a matching title/merchant pattern.
  2. If unmatched and the user has enabled BYOK AI categorization with a valid API key (Gemini or OpenAI-compatible), batch all unmatched descriptions along with the user's active category list in one prompt to request category assignments.
  3. If AI is unconfigured, offline, or returns no valid category match, assign the default "Unknown" category.
- **Immediate Insertion and Review Flow (ADR-0002)**: All settled (`pending == false`) transactions returned by SimpleFIN are inserted immediately into the Transactions table so budgets and Wallet sums reflect them right away. Each inserted transaction is marked as unreviewed. A review view (patterned after the existing email/notification auto-transactions UI) lists Unreviewed Transactions so users can confirm them or change their category. Changing a category during review automatically records or updates an `AssociatedTitle` rule.
- **Transfers**: Cross-account transfers (e.g., paying a synced credit card from a synced checking account) are imported as independent Synced Transactions in v1; users categorize or exclude them manually during review.
- **Balance Reconciliation**: Each sync updates the Wallet's stored external bank balance and balance date. When the bank balance differs from Cashew's calculated ledger sum, the UI displays both and provides a one-tap action to insert a standard Cashew Balance Correction transaction for the delta.

## Testing Decisions

- **Testing Philosophy**: Tests must exercise external behavior and state transitions across module boundaries rather than testing private helper functions or UI layout details. Mock only external network boundaries (SimpleFIN HTTP endpoints and the optional AI provider HTTP endpoint); run all persistence, deduplication, and categorization logic against a real in-memory Drift SQLite database.
- **Prior Art**: Currently, the repository only contains a placeholder Flutter widget smoke test. This feature will introduce service-level unit and integration tests using `flutter_test` and an in-memory Drift executor.
- **Primary Testing Seams**:
  1. **SimpleFIN Sync Service Seam**: Invoke the sync orchestrator with mocked SimpleFIN HTTP responses and an in-memory Drift database. Verify end-to-end behavior: token claim and secure storage persistence, settled vs pending filtering, idempotent deduplication across repeated syncs, 1:1 Wallet mapping, currency mismatch rejection, `AssociatedTitles` matching, batched BYOK AI fallback, "Unknown" fallback, stored bank balance updates, and partial error handling when SimpleFIN returns account-level errors.
  2. **Review and Learning Seam**: Invoke the review confirmation and recategorization actions against the in-memory Drift database. Verify that confirming clears the unreviewed state and recategorizing updates both the transaction and `AssociatedTitles` so a subsequent sync matches locally without calling the AI mock.
  3. **Balance Reconciliation Seam**: Invoke balance reconciliation on a linked Wallet whose ledger sum differs from the stored bank balance, verifying that a Balance Correction transaction is created for the exact delta.

## Out of Scope

- Backend proxy server or cloud-hosted SimpleFIN credential relay.
- Flutter Web support for SimpleFIN syncing (blocked by browser CORS without a proxy).
- Automatic cross-account transfer matching or pairing between two synced Wallets.
- Importing or displaying pending bank transactions before they settle.
- Built-in developer-funded AI API keys or hosted ML categorization.
- Splitting a single Synced Transaction automatically during import.

## Further Notes

- Domain terminology is defined in `GLOSSARY.md` at the repository root.
- Architectural trade-offs are recorded in `docs/adr/0001-direct-client-simplefin-sync.md` and `docs/adr/0002-immediate-budget-insertion-with-post-hoc-review.md`.
