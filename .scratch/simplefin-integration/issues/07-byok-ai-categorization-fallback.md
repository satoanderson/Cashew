# 07: Optional BYOK AI categorization fallback

**What to build:** Users can configure an opt-in "Bring Your Own Key" AI provider (Gemini or OpenAI-compatible endpoint) in settings. During sync, any transactions unmatched by `AssociatedTitles` are batched in a single request (sending only merchant descriptions and category names) to assign categories before falling back to "Unknown" if unconfigured, offline, or invalid.

**Blocked by:** 03: Manual Sync Now for settled Synced Transactions with deduplication

**Status:** resolved

- [x] Settings allow enabling BYOK AI categorization, selecting Gemini or OpenAI-compatible endpoint, and storing the API key in Flutter Secure Storage.
- [x] Unmatched transaction descriptions from a sync are batched into a single AI prompt containing only descriptions and user category names (never credentials, account numbers, or balances).
- [x] Valid AI category matches assign the corresponding Cashew category; invalid or unknown responses fall back to "Unknown".
- [x] If AI is disabled, unconfigured, offline, or errors out, sync succeeds by falling back to "Unknown".
- [x] Mocked AI HTTP + in-memory Drift tests verify batching, payload privacy (no balances/tokens), and graceful fallback to "Unknown".
