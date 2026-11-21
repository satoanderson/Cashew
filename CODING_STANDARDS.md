# Coding standards

Judgement-call rules for code review. Mechanical checks live in `budget/analysis_options.yaml` and `.github/workflows/flutter-ci.yml`.

## User-facing entrypoints

- When a spec references an existing Cashew surface (Home, Settings, Wallets), wire the entrypoint into that surface rather than hiding it only inside a Settings subpage.

## Drift streams and services in widgets

- Hold Drift `.watch()` streams in widget `State` (for example `late final Stream<...>`) instead of creating new streams inside `build()`.
- Avoid instantiating services that allocate `http.Client` or `FlutterSecureStorage` inside `build()`; expose static query helpers or initialize the service once in `initState`.

## Platform gating

- Gate direct third-party HTTP integrations blocked by browser CORS with `!kIsWeb` so Flutter Web builds do not expose broken flows.
