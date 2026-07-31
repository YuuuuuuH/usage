# Codex Token Atlas

Codex Token Atlas scans local Codex session logs and builds a route-aware token dashboard for macOS. It uses a native SwiftUI/AppKit interface with no embedded browser or WebKit dependency. The app includes a 7 x 24 hourly heatmap, daily history, session and model breakdowns, fork deduplication, filtered exports, and an official direct-API equivalent value estimate.

All session parsing and report generation happen locally. The repository does not contain session logs, prompts, generated reports, or personal usage data.

## Highlights

- Keeps `total_tokens` as the primary usage metric, including cached input and any unclassified total reported by Codex.
- Attributes every call to the nearest preceding model, provider, service tier, and reasoning-effort settings instead of assigning one final setting to the whole session.
- Deduplicates inherited fork history using lineage root, turn ID, cumulative usage, per-call usage, and context window.
- Aggregates usage into continuous-color 7 x 24 and daily heatmaps.
- Shows tokens, calls, and the selected official direct-API equivalent value for every hourly and daily heatmap cell on hover.
- Filters the whole dashboard by all history, the latest 7 or 30 days, or an exact custom date range.
- Switches between a simple Standard-rate estimate and a service-tier estimate that distinguishes Default from Fast/Priority calls.
- Separates Standard/default and Priority/Fast API rates where the provider publishes both.
- Prices current and historical GPT/Codex families plus built-in DeepSeek, Gemini, Anthropic, and xAI models. Unknown models remain visible and are marked unpriced.
- Reads cache hits and cache writes separately when the log schema provides them.
- Adds date- and model-aware official value columns to session and route reporting.
- Keeps All Time, last-7-day, and last-30-day ranges anchored to the newest report date after every refresh.
- Lets the user choose the export format and destination for filtered JSON, daily/hourly/model/route/session CSV, complete HTML, or all formats together.
- Provides standard macOS Edit menu actions, including copy, paste, and select all.
- Adds an optional native menu-bar monitor with a compact 60-second rolling Token rate plus historical total and input/cache/output details in its panel.
- Uses native Liquid Glass for macOS 26 toolbars, controls, summary bands, and the live panel, with system-material fallbacks on older supported releases.
- Defaults live detection to 5 seconds and provides persistent 1-, 2-, or 5-second choices while reading only bytes appended to local session logs.
- Places Dock presence, System/Light/Dark appearance, and live refresh controls in the toolbar Settings menu immediately left of Refresh.

## Accounting

The dashboard sums unique `last_token_usage` events. When that field is missing, it falls back to a non-negative delta of cumulative usage. `reasoning_output_tokens` is treated as part of output and is not added to the total a second time.

The menu-bar monitor is off by default and can be enabled from the main toolbar or application menu. Its compact readout remains the 60-second live rate; the expanded panel adds the all-time total, published once per minute. It baselines files that already exist when it starts and waits until newly discovered files stop growing before reading appended events. This prevents inherited fork history from appearing as fresh throughput. The selected refresh interval controls how quickly appended log events are detected, not the averaging window. Codex writes usage after model calls rather than as a token stream, so an in-flight call becomes visible only after its `token_count` event reaches disk. Dragging the live panel away from the menu bar pins it as a normal persistent window without forcing it above other apps. Closing the dashboard leaves an enabled monitor running, and clicking its compact menu-bar readout opens the live panel. Hiding the Dock icon automatically keeps that status item available; disabling it restores the Dock icon so the app cannot become unreachable.

Codex `/status` may show a much smaller number because its displayed token usage generally resembles uncached input plus output. Token Atlas intentionally preserves the complete `total_tokens` field from local logs.

The value panel is deliberately not labelled as an actual bill. Its controls offer two comparison modes:

- **Simple pricing:** every recognized call uses the model's official Standard API rate.
- **Default / Fast pricing:** logged Default calls use Standard rates and logged Fast/Priority calls use official Priority rates when available, with an explicit Standard fallback when no Priority rate exists.

Older logs may not contain a service tier. Those calls use the current top-level `service_tier` from `~/.codex/config.toml` as an inferred fallback, and the audit panel reports exactly how many calls were inferred. This improves historical estimates without claiming that the current setting proves the original route.

Channel interpretation remains separate from those controls:

- **ChatGPT Plan:** local token events cannot reconstruct subscription charges or Codex credits. Standard API equivalent value is still shown for comparison. Fast-mode credit multipliers are not dollar token prices.
- **OpenAI API key:** `default` uses Standard rates and logged `priority`/`fast` routes use published Priority rates when available.
- **Other provider or relay:** the logged provider and model are retained. A recognized DeepSeek, Gemini, Claude, Grok, or GPT model is valued at that vendor's official direct rate even when it was reached through an OpenAI-compatible relay.
- **Unknown or internal model:** usage remains in every total and export, but value is unpriced until it can be mapped to a built-in official model.

Unclassified tokens are excluded from value. Cache writes use a published write rate when one exists; otherwise they use the uncached input rate. Pricing sources are listed in the generated report.

## Official model aliases

Create `~/.codex/token_atlas_pricing.json` only when a relay logs an internal model name that should map to a known official model. The repository includes [an example](examples/token_atlas_pricing.example.json).

An alias can be global or scoped to a logged provider:

```json
{
  "aliases": {
    "CompanyRelay/internal-gpt": "gpt-5.6-sol",
    "internal-deepseek": "deepseek-v4-pro"
  }
}
```

Alias targets must exist in the app's built-in official catalog. Custom relay prices and contract rates are intentionally rejected, so the report always answers one question: what would the same logged model usage be worth through its official API channel?

The current authentication mode is shown only as context. Codex logs do not preserve enough historical authentication data to prove whether every old call was billed through a plan, an API account, or a relay.

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

Release tags use the semantic app version, such as `v2.1.4`. Bump `CFBundleShortVersionString` before every push so each commit produces a distinct installer without rewriting earlier releases.

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
- `~/codex_token_usage_by_route.csv`
- `~/codex_token_usage_by_session.csv`
- `~/codex_token_usage_summary.json`

Pricing data is versioned in `src/codex_token_heatmap.py` with an `as_of` date. Models without a matching official rate are still fully counted but excluded from the value estimate.
