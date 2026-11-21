# Development and emulator setup

Non-obvious commands and gotchas for working on Cashew in this repo.

## Layout and checks

- The Flutter app lives in `budget/`, not the repo root.
- Toolchain versions are pinned in `mise.toml` (Flutter `3.19.6`, Java `17`, `android-sdk`).
- Run checks before any Gradle or emulator test run:
  ```bash
  mise run check
  ```
- `budget/test/widget_test.dart` is an upstream commented-out placeholder; run `flutter test test/simplefin_sync_test.dart` until it is replaced.

## Cashew code gotchas

- `budget/lib/database/tables.dart` conditionally exports `constructDb` via `platform/shared.dart`. Do not import `platform/native.dart` alongside `tables.dart` (causes an ambiguous import).
- `PageFramework` uses a custom back button rather than Material `BackButton`, so `WidgetTester.pageBack()` fails in integration tests; pop the route via `Navigator.of(...).pop()`.

## Android emulator in WSL2

- AVD: `cashew_api34` (`system-images;android-34;google_apis;x86_64`, `pixel_6`).
- KVM access requires membership in the `kvm` group (`sudo gpasswd -a $USER kvm`, then `wsl --shutdown`).
- Headless emulator for automated `integration_test` runs (no Qt GUI dependencies):
  ```bash
  mise exec -- emulator -avd cashew_api34 -no-window -no-audio -no-metrics -no-snapshot-save -gpu swiftshader_indirect
  cd budget && mise exec -- flutter test integration_test/simplefin_e2e_test.dart -d emulator-5554
  ```
- GUI emulator on WSLg requires `libpulse0 libnss3 libnspr4 libxkbfile1 libxcb-cursor0 libxkbcommon-x11-0 libxcb-icccm4 libxcb-keysyms1 libxcb-shape0 libxcb-xinerama0 libxcb-xinput0 libxcb-xkb1 libsm6 libice6` and `QT_QPA_PLATFORM=xcb`:
  ```bash
  QT_QPA_PLATFORM=xcb mise exec -- emulator -avd cashew_api34 -no-snapshot-save -gpu swiftshader_indirect
  ```
- When debugging interactively, tee logs to `.scratch/flutter-run.log` so agents can inspect runtime output without copy-paste:
  ```bash
  cd budget && mise exec -- flutter run | tee ../.scratch/flutter-run.log
  ```
