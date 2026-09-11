# Codex Token Atlas 0.3.7 QA

This report covers version 0.3.7 of `YuuuuuuH/usage`, compared with the 0.3.3 baseline.

The update adds theme presets, a native color picker, HEX input, adaptive contrast, and a reproducible native heatmap “T” icon. Usage browsing includes a 7×24 overview, daily history with expandable hours, and searchable, paginated sessions. Heatmap tooltips follow the pointer, show immediate cell outlines, and avoid window edges.

Achievements include 12 tracks, tiered medals, hidden diamond tiers on selected tracks, personal usage records, and model footprints. The menu-bar panel offers per-source and combined usage scopes. Additional changes cover cached-event repricing, pricing validation, usage-category presentation, safe exports, and corrections to live historical reconciliation and replay timing.

## Verification

The following checks passed locally:

- Python synthetic tests.
- Swift live-monitor, theme, and tooltip-geometry tests.
- Opt-in native tooltip lifecycle and `mouseMoved` integration tests.
- Universal macOS 12+ builds for arm64 and x86_64.
- Installed-app smoke tests and ad-hoc signature/hash checks.

Local UI interaction checks were also performed.

To run the default test suites and produce a universal build:

```sh
./scripts/build_app.sh
```

To additionally run native tooltip integration tests on a machine with WindowServer:

```sh
TOKEN_ATLAS_TEST_NATIVE_HOVER=1 ./scripts/build_app.sh
```

## Verification limits

Intel and older macOS targets were compiled but were not runtime-tested. GPU load was not quantitatively benchmarked. Check the repository's Actions page for remote workflow status.
