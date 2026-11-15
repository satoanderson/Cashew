# Cashew

Personal finance and budgeting application for tracking accounts, expenses, income, and budgets.

## Language

**Wallet**:
A financial account (such as a checking account, credit card, or cash balance) owned by the user.
_Avoid_: Account, Bank Account

**SimpleFIN Connection**:
An authenticated link to a SimpleFIN Bridge that provides read-only access to one or more external bank accounts.
_Avoid_: Bank Link, Bridge Auth

**Synced Transaction**:
A settled financial transaction imported from an external bank feed and associated with a Wallet.
_Avoid_: Bank Transaction, Feed Entry

**Unreviewed Transaction**:
A Synced Transaction that has been added to active budgets and Wallet totals, but has not yet been confirmed or recategorized by the user.
_Avoid_: Pending Transaction, Staged Transaction
