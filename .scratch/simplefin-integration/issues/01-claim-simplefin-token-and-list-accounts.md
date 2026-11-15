# 01: Claim SimpleFIN Setup Token and list external accounts

**What to build:** On Mobile and Desktop (hidden on Web), a user can open SimpleFIN settings, paste a SimpleFIN Setup Token, exchange it directly over HTTPS for an Access URL stored in Flutter Secure Storage, view the returned external bank accounts, and unlink or delete the connection.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] SimpleFIN settings entry is visible on Android, iOS, and Desktop, and hidden on Flutter Web.
- [x] Pasting a base64 Setup Token exchanges it via HTTP POST to the claim URL and persists the Access URL in Flutter Secure Storage.
- [x] A SimpleFIN Connection record is persisted in Drift with connection label, status, and secure-storage key reference.
- [x] Fetching the `/accounts` endpoint displays all external bank accounts returned by the SimpleFIN Connection.
- [x] Deleting a SimpleFIN Connection removes its stored Access URL and connection record without deleting local Wallets or historical transactions.
- [x] Mocked HTTP + in-memory Drift tests verify token claim, account listing, and connection removal.
