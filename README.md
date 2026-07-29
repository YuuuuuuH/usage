# Codex Token Atlas

Codex Token Atlas scans local Codex session logs and builds a model-aware token dashboard for macOS. It includes a native AppKit shell, a 7 x 24 hourly heatmap, daily history, session and model breakdowns, fork deduplication, CSV/JSON exports, and an API-equivalent cost estimate.

All session parsing and report generation happen locally. The repository does not contain session logs, prompts, generated reports, or personal usage data.

## Highlights

- Keeps `total_tokens` as the primary usage metric, including cached input and any unclassified total reported by Codex.
- Attributes every call to the nearest preceding `turn_context` model instead of assigning one final model to the whole session.
- Deduplicates inherited fork history using lineage root, turn ID, cumulative usage, per-call usage, and context window.
- Aggregates usage into continuous-color 7 x 24 and daily heatmaps.
- Shows the API cost estimate for each heatmap cell on hover.
- Prices current and historical GPT families, Codex variants, and older reasoning models; unknown future models remain visible and are marked unpriced.
- Exports daily, hourly, model, session, and audit data.
- Provides standard macOS Edit menu actions, including copy, paste, and select all.

## Accounting

The dashboard sums unique `last_token_usage` events. When that field is missing, it falls back to a non-negative delta of cumulative usage. `reasoning_output_tokens` is treated as part of output and is not added to the total a second time.

Codex `/status` may show a much smaller number because its displayed token usage generally resembles uncached input plus output. Token Atlas intentionally preserves the complete `total_tokens` field from local logs.

Cost values are estimates using OpenAI standard API text-token prices, not actual Codex or ChatGPT subscription charges. Unclassified tokens are excluded. GPT-5.6 session logs do not distinguish cache reads from cache writes, so cached input is estimated at the cache-read rate. See the [official OpenAI pricing table](https://developers.openai.com/api/docs/pricing).

## Requirements

- macOS 12 or later
- Xcode Command Line Tools or Xcode
- Python 3.9 or later
- Local Codex sessions under `~/.codex/sessions`

## Build

Build and ad-hoc sign the Universal macOS app:

```bash
./scripts/build_app.sh
```

Build the app and distributable DMG:

```bash
./scripts/build_dmg.sh
```

Artifacts are written to `dist/`.

## Releases

Every branch push triggers `.github/workflows/release.yml`. The workflow runs the regression tests, builds and verifies a Universal macOS DMG, and creates a uniquely tagged GitHub Release containing:

- `Codex-Token-Atlas.dmg`
- `Codex-Token-Atlas.dmg.sha256`

Release tags use `v<app-version>-build.<workflow-run-number>`, so each push produces a separate installer without rewriting earlier releases.

## Generator

Run the report generator without the app:

```bash
python3 src/codex_token_heatmap.py
```

Run synthetic regression tests:

```bash
python3 src/codex_token_heatmap.py --self-test
```

Generated files are written to the home directory:

- `~/codex_token_heatmap.html`
- `~/codex_token_usage_by_day.csv`
- `~/codex_token_usage_by_hour.csv`
- `~/codex_token_usage_by_model.csv`
- `~/codex_token_usage_by_session.csv`
- `~/codex_token_usage_summary.json`

Pricing data is versioned in `src/codex_token_heatmap.py` with an `as_of` date. Models without a matching official standard rate are still fully counted but excluded from the cost estimate.
