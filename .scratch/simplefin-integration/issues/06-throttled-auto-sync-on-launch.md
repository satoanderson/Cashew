# 06: Throttled auto-sync on app launch

**What to build:** Opening Cashew on Mobile or Desktop automatically runs SimpleFIN sync in the background when at least 4 hours have passed since a connection's last sync, respecting SimpleFIN's daily rate limits and surfacing HTTP 402/403/429 errors without blocking app startup.

**Blocked by:** 03: Manual Sync Now for settled Synced Transactions with deduplication

**Status:** resolved

- [x] App launch triggers SimpleFIN sync asynchronously only for connections whose last sync was 4 or more hours ago.
- [x] Connections synced less than 4 hours ago are skipped during launch auto-sync.
- [x] Manual "Sync Now" bypasses the 4-hour launch throttle.
- [x] HTTP 402/403/429 responses record a clear status message on the connection without crashing or blocking startup.
- [x] Tests verify 4-hour throttle enforcement and rate-limit/auth error handling.
