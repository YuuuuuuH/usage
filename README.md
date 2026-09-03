# Codex Token Atlas

Codex Token Atlas scans a selected Codex-compatible data home and builds a route-aware token dashboard for macOS. It supports the standard `~/.codex` home, local Qodex at `~/.qodex`, and other compatible directories without mixing their usage. The app uses a native SwiftUI/AppKit interface with no embedded browser or WebKit dependency.

All session parsing and report generation happen locally. The repository does not contain session logs, prompts, generated reports, or personal usage data.

## Highlights

- Keeps `total_tokens` as the primary usage metric, including cached input and any unclassified total reported by Codex.
- Attributes every call to the nearest preceding model, provider, service tier, and reasoning-effort settings instead of assigning one final setting to the whole session.
- Separates user forks from internal worker threads using recorded lineage metadata. Worker usage is deduplicated and rolled into its user-visible conversation, while reasoning effort remains an independent route dimension.
- Deduplicates inherited history using physical lineage root, turn ID, route, cumulative usage, per-call usage, and context window.
- Aggregates usage into continuous-color 7 x 24 and daily heatmaps.
- Shows tokens, calls, and the selected official direct-API equivalent value for every hourly and daily heatmap cell on hover.
- Selects `~/.codex`, `~/.qodex`, or another compatible data home from the dashboard, then filters that source by model, metric, all history, the latest 7 or 30 days, or an exact custom date range.
- Switches between a simple Standard-rate estimate and a service-tier estimate that distinguishes Default from Fast/Priority calls.
- Separates Standard/default and Priority/Fast API rates where the provider publishes both.
- Prices current and historical GPT/Codex families plus built-in DeepSeek, Gemini, Anthropic, and xAI models. Unknown models remain visible and are marked unpriced.
- Stores optional per-model prices for local and open-source models inside the selected data home, with separate uncached input, cache read, cache write, and output rates.
- Reads cache hits and cache writes separately when the log schema provides them.
- Adds date- and model-aware official value columns to session and route reporting.
- Keeps All Time, last-7-day, and last-30-day ranges anchored to the newest report date after every refresh.
- Lets the user choose the export format and destination for filtered JSON, daily/hourly/model/route/session CSV, complete HTML, or all formats together.
- Provides standard macOS Edit menu actions, including copy, paste, and select all.
- Adds an optional native menu-bar monitor with a compact 60-second rolling Token rate plus historical total and input/cache/output details in its panel.
- Uses native Liquid Glass for macOS 26 toolbars, controls, summary bands, and the live panel, with system-material fallbacks on older supported releases. Persistent, independent Settings sliders adjust the main app and menu-bar panel from clear to frosted without stacking extra blur layers; macOS 27 system glass preferences still flow through the native material.
- Defaults live detection to 5 seconds and provides persistent 1-, 2-, or 5-second choices while reading only bytes appended to local session logs.
- Places Dock presence, System/Light/Dark appearance, and live refresh controls in the toolbar Settings menu immediately left of Refresh.

## Accounting

The dashboard sums unique `last_token_usage` events. When that field is missing, it falls back to a non-negative delta of cumulative usage. Reported `reasoning_output_tokens` is treated as part of output and is not added to the total a second time. If a compatible provider leaves that field at zero but stores plaintext reasoning response items, Token Atlas derives the reasoning subset with a matching local Hugging Face `tokenizer.json` when available and records the inference in the audit panel; a conservative text estimate is used as a fallback. An exact model-to-tokenizer path can be supplied in `<data-home>/token_atlas_tokenizers.json`.

The menu-bar monitor is off by default and can be enabled from the main toolbar or application menu. It follows the currently selected data home, keeps historical totals separate by directory, and resets its live window when the directory changes. Its compact readout remains the 60-second live rate; the expanded panel adds the selected source's all-time total. It baselines files that already exist when it starts and waits until newly discovered files stop growing before reading appended events. This prevents inherited history from appearing as fresh throughput. The selected refresh interval controls how quickly appended log events are detected, not the averaging window. Usage appears after a model call writes its `token_count` event to disk.

The session table represents user-visible conversations. Internal `subagent`/worker rollouts remain part of token, model, date, and cost totals, but are recursively folded into their owning conversation. Explicit user forks remain separate rows. The audit panel reports rollout files, conversations, user forks, internal threads, and orphan internal threads independently.

Refreshes keep an append-only parser cache under `~/Library/Caches/CodexTokenAtlas`. After the first full rebuild, unchanged files are reused and growing rollout files are read only from their previous byte offset while retaining fork-deduplication state. A rewritten, truncated, removed, or structurally changed rollout invalidates the cache and triggers a safe full rebuild. The dashboard remains visible behind a compact progress badge during a background refresh.

Codex `/status` may show a much smaller number because its displayed token usage generally resembles uncached input plus output. Token Atlas intentionally preserves the complete `total_tokens` field from local logs.

The value panel is deliberately not labelled as an actual bill. Its controls offer two comparison modes:

- **Simple pricing:** every recognized call uses the model's official Standard API rate.
- **Default / Fast pricing:** logged Default calls use Standard rates and logged Fast/Priority calls use official Priority rates when available, with an explicit Standard fallback when no Priority rate exists.

Older logs may not contain a service tier. For the standard `~/.codex` home, those calls use the current top-level `service_tier` from `~/.codex/config.toml` as an inferred fallback, and the audit panel reports exactly how many calls were inferred. Alternate data homes use Default without reading their auth or provider configuration.

Channel interpretation remains separate from those controls:

- **ChatGPT Plan:** local token events cannot reconstruct subscription charges or Codex credits. Standard API equivalent value is still shown for comparison. Fast-mode credit multipliers are not dollar token prices.
- **OpenAI API key:** `default` uses Standard rates and logged `priority`/`fast` routes use published Priority rates when available.
- **Other provider or relay:** the logged provider and model are retained. A recognized DeepSeek, Gemini, Claude, Grok, or GPT model is valued at that vendor's official direct rate even when it was reached through an OpenAI-compatible relay.
- **Unknown or internal model:** usage remains in every total and export, but value is unpriced until it can be mapped to a built-in official model.

Qodex and custom data homes operate as token-accounting sources. Their models and calls are fully filterable, and remain unpriced until a per-model price is saved from Settings. Model names in alternate data homes do not automatically inherit official API prices.

Unclassified tokens are excluded from value. Cache writes use a published write rate when one exists; otherwise they use the uncached input rate. Pricing sources are listed in the generated report.

## Model pricing and aliases

Use **Settings → Open-source/local model pricing…** to save prices for currently unpriced models in the selected data home. Models already covered by the built-in official catalog are omitted. Prices use USD per one million tokens and are stored in `<data-home>/token_atlas_pricing.json`. Input and output are required; cache read and cache write default to the input rate when left blank.

The same file can map a relay's internal model name to another priced model. The repository includes [an example](examples/token_atlas_pricing.example.json).

Prices are exact per model, while an alias can be global or scoped to a logged provider:

```json
{
  "models": {
    "Qwen3.8-27B": {
      "provider": "Qodex",
      "input": 0.20,
      "cached_input": 0.05,
      "cache_write_input": 0.20,
      "output": 0.80
    }
  },
  "aliases": {
    "LocalRelay/qwen-latest": "qwen3.8-27b"
  }
}
```

Alias targets must exist in either the app's built-in official catalog or the file's `models` section. In the standard Codex home, built-in official prices take precedence; Qodex and custom data homes use only prices explicitly saved for that source.

The current authentication mode is shown only as context. Codex logs do not preserve enough historical authentication data to prove whether every old call was billed through a plan, an API account, or a relay.

## Requirements

- macOS 12 or later
- Xcode Command Line Tools or Xcode
- Python 3.9 or later
- A local Codex-compatible data home containing `sessions/`

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

Choose another compatible data home, for example local Qodex:

```bash
python3 src/codex_token_heatmap.py --data-home ~/.qodex
```

Run synthetic regression tests:

```bash
python3 src/codex_token_heatmap.py --self-test
```

Generated files for the currently selected data home are written to the home directory:

- `~/codex_token_heatmap.html`
- `~/codex_token_usage_by_day.csv`
- `~/codex_token_usage_by_hour.csv`
- `~/codex_token_usage_by_model.csv`
- `~/codex_token_usage_by_route.csv`
- `~/codex_token_usage_by_session.csv`
- `~/codex_token_usage_summary.json`

Pricing data is versioned in `src/codex_token_heatmap.py` with an `as_of` date. Models without a matching official rate are still fully counted but excluded from the value estimate.
