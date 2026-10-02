# Codex Token Atlas

Codex Token Atlas scans a selected Codex-compatible data home and builds a route-aware token dashboard for macOS. It supports the standard `~/.codex` home, local Qodex at `~/.qodex`, and other compatible directories without mixing their usage. The app uses a native SwiftUI/AppKit interface with no embedded browser or WebKit dependency.

All session parsing and report generation happen locally. The repository does not contain session logs, prompts, generated reports, or personal usage data.

## Highlights

- Keeps `total_tokens` as the primary usage metric, including cached input and any unclassified total reported by Codex.
- Attributes every call to the nearest preceding model, provider, service tier, and reasoning-effort settings instead of assigning one final setting to the whole session.
- Separates user forks from internal worker threads using recorded lineage metadata. Worker usage is deduplicated and rolled into its user-visible conversation, while reasoning effort remains an independent route dimension.
- Deduplicates inherited history using physical lineage root, turn ID, route, cumulative usage, per-call usage, and context window.
- Aggregates usage into continuous-color 7 x 24 and daily heatmaps.
- Uses a neutral slate-and-blue adaptive palette, responsive hourly grids, and an expandable daily detail strip below the calendar.
- Offers presets, a native color picker, and HEX input under Settings → Personalization (⌘,). Accent colors and heatmaps update immediately; light/dark variants preserve readable contrast.
- Opens on the 7 × 24 dashboard. Recent-achievement, next-level and peak-speed summaries follow the daily history. The Achievements page contains 12 achievement tracks, personal records, daily highlights, model footprints and a milestone timeline.
- Provides persistent section navigation and searchable, paginated session tables. Session and pricing columns fit the window; truncated text remains available on hover.
- Shows tokens, calls, and the selected official direct-API equivalent value for every hourly and daily heatmap cell on hover.
- Selects `~/.codex`, `~/.qodex`, or another compatible data home from the dashboard, then filters that source by model, metric, all history, the latest 7 or 30 days, or an exact custom date range.
- Switches between a simple Standard-rate estimate and a service-tier estimate that distinguishes Default from Fast/Priority calls.
- Separates Standard/default and Priority/Fast API rates where the provider publishes both.
- Prices current and historical GPT/Codex families plus built-in DeepSeek, Gemini, Anthropic, and xAI models. The 2026-09-07 catalog includes GPT-6 Astra, GPT-5.6 Sol/Terra/Luna/Cyber, Gemini 3.8 Flash, Claude 5/5.1, and Grok 4.6. Unknown models remain visible and are marked unpriced.
- Stores optional per-model prices for local and open-source models inside the selected data home, with separate uncached input, cache read, cache write, and output rates.
- Reads cache hits and cache writes separately when the log schema provides them.
- Adds date- and model-aware official value columns to session and route reporting.
- Keeps All Time, last-7-day, and last-30-day ranges anchored to the newest report date after every refresh.
- Lets the user choose the export format and destination for filtered JSON, daily/hourly/model/route/session CSV, complete HTML, or all formats together.
- Provides standard macOS Edit menu actions, including copy, paste, and select all.
- Adds an optional native menu-bar monitor with a compact 60-second rolling Token rate plus historical total and input/cache/output details in its panel. The panel switches instantly between Codex, Qodex, and an aggregate of every available source without rebuilding the historical report.
- Uses native Liquid Glass for macOS 26 toolbars, controls, summary bands, and the live panel, with system-material fallbacks on older supported releases. Persistent, independent Settings sliders adjust the main app and menu-bar panel from clear to frosted without stacking extra blur layers; macOS 27 system glass preferences still flow through the native material.
- Defaults live detection to 5 seconds and provides persistent 1-, 2-, or 5-second choices while reading only bytes appended to local session logs.
- Places Dock presence, System/Light/Dark appearance, and live refresh controls in the toolbar Settings menu immediately left of Refresh.

## Accounting

The dashboard sums unique `last_token_usage` events. When that field is missing, it falls back to a non-negative delta of cumulative usage. Reported `reasoning_output_tokens` is treated as part of output and is not added to the total a second time. If a compatible provider leaves that field at zero but stores plaintext reasoning response items, Token Atlas derives the reasoning subset with a matching local Hugging Face `tokenizer.json` when available and records the inference in the audit panel; a conservative text estimate is used as a fallback. An exact model-to-tokenizer path can be supplied in `<data-home>/token_atlas_tokenizers.json`.

The menu-bar monitor is off by default and can be enabled from the main toolbar or application menu. Its panel switches directly between Codex, Qodex, and all available sources; the aggregate view combines each source's independent rolling window and historical total without changing the dashboard's selected data home or starting a report refresh. Historical totals are the last confirmed report values, reconciled on refresh rather than accumulated from live samples; a source that has not been refreshed is shown as pending. The compact readout shows the selected scope's total 60-second Token rate. It baselines files that already exist when it starts and waits until newly discovered files stop growing before reading appended events. This prevents inherited history from appearing as fresh throughput. The selected refresh interval controls how quickly appended log events are detected, not the averaging window. Usage appears after a model call writes its `token_count` event to disk.

The session table represents user-visible conversations. Internal `subagent`/worker rollouts remain part of token, model, date, and cost totals, but are recursively folded into their owning conversation. Explicit user forks remain separate rows. The audit panel reports rollout files, conversations, user forks, internal threads, and orphan internal threads independently.

Refreshes keep an append-only parser cache under `~/Library/Caches/CodexTokenAtlas`. After the first full rebuild, unchanged files are reused and growing rollout files are read only from their previous byte offset while retaining fork-deduplication state. Pricing revisions and edits to per-source prices revalue stored billable events directly without rereading unchanged session logs. A rewritten, truncated, removed, or structurally changed rollout invalidates the cache and triggers a safe full rebuild. The dashboard remains visible behind a compact progress badge during a background refresh, preserving the scroll position and expanded day within the same source. Report decoding runs off the UI thread.

Startup and source switching first display that source's last saved report, labelled as updating, while fresh statistics are prepared. Unrelated preferences and credential rotation preserve the parser cache. Inferred service-tier changes reuse recorded calls when deduplication remains equivalent; separate Default/Priority checkpoints cover histories that require distinct deduplication. A missing checkpoint or legacy attribution may require one rebuild. Session metadata and achievement records are reused until their inputs change, and JSON/HTML share one dashboard calculation. Refresh-stage timings are written to the local app log.

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

Unclassified tokens (`total − input − output`) are retained in usage but excluded from value because their billing category is unknown. The native route table distinguishes this from a model with no matching price and from a missing category rate. Cache writes use a published write rate when one exists; otherwise they use the uncached input rate. DeepSeek V4 historical value follows its official UTC weekday peak/off-peak schedule; the route table shows the peak rate. Pricing sources are listed in the generated report.

## Personal records

Records and achievements cover the selected data home's entire history and all models, independently of detail filters. They are rebuilt locally from deduplicated cached events. Worker threads contribute usage to their owning conversation; they do not count as extra conversations for badges. No extra log scan is needed for these records.

The Achievements page leads with peak total/output Token-per-second cards, followed by conversation-volume and continuous-activity records. Each speed is the maximum of an independent rolling `(end − 60 seconds, end]` window, divided by 60. The headings identify the speed, compact values carry a small `60 秒平均` caption, and same-day ranges share one date. Exact counts and calculations are available on hover; calculation rules expand below the cards. Total includes input and cache traffic; output is shown separately. Log-reported throughput does not reconstruct instantaneous model decoding speed. Continuous activity joins events in one logical conversation when adjacent reports are at most 30 minutes apart; the displayed span is not a measured task execution duration. A single isolated event has no measurable duration. Sessions with incomplete timestamps are excluded from time-based records. The report also retains 60-minute volume windows for JSON consumers.

Timing records also exclude recognized inherited replay whose occurrence timestamps were rewritten when a child rollout was created. The existing parser cache retains ordered fingerprints with physical-rollout and turn IDs; this pairing is validated before use. A UUIDv7 turn predating its fork by more than one second, but recorded at or after the fork's creation, identifies an unsuitable copied-history timestamp. Post-fork records with missing or unrecognized turn chronology are excluded as unverified; preserved pre-fork timestamps remain eligible. Exclusion counts are shown alongside the records. This timing filter leaves the underlying token/cost accounting unchanged.

An active day has positive token usage in the report timezone. The current streak may end today or yesterday. Bronze/silver/gold streak tiers use 3 / 7 / 14 consecutive days. Earned streak tiers use the historical best, while progress toward the next tier uses the current streak. Cumulative active-day tiers use 7 / 30 / 90 days and can be earned across interruptions; conversation tiers use 10 / 30 / 100 logical conversations. Achievements reflect the logs currently available in that data home; removing historical logs can change them.

The overview places clickable recent-achievement, next-level and peak-output-speed summaries immediately after daily history. These summaries cover the current source's full history and all models. The full Achievements page adds category/status filters, independent daily total/output/conversation records, the most model-diverse conversation, model footprints and a dated milestone timeline. The wall's All category displays a continuous three-column grid; individual categories remain selectable. Achievement definitions are available on hover. Daily/session record links reveal their corresponding detail filters. Model footprints combine case-normalized reported identities across service tiers; pricing aliases do not redefine model identity.

The wall has 12 families. Bronze, silver and gold recognize early, established and sustained use. Exploration tracks recognize breadth, and volume tracks recognize usage scale. Their thresholds are fixed product milestones, not population percentiles or equal measures of effort.

| Category | Family | Bronze / silver / gold |
| --- | --- | --- |
| Habit | Continuous use | 3 / 7 / 14 days |
| Habit | Cumulative active days | 7 / 30 / 90 days |
| Habit | Conversations | 10 / 30 / 100 |
| Exploration | Distinct models | 2 / 4 / 6 |
| Exploration | Models in one conversation | 2 / 3 / 4 |
| Exploration | Conversations in one local day | 2 / 4 / 8 |
| Collaboration | Conversations with internal workers | 3 / 10 / 30 |
| Collaboration | Cumulative collaborative days | 3 / 10 / 30 days |
| Volume | Total Token | 100M / 1B / 5B |
| Volume | Output Token | 1M / 5M / 20M |
| Volume | Reasoning Token | 500K / 2M / 10M |
| Volume | Cached-input Token | 100M / 1B / 5B |

Worker participation requires validated physical provenance and an own post-creation call. Collaborative days additionally require eligible local timestamps, and merge all workers/conversations on the same date into one day. The most participating workers in one conversation is retained as a personal record with a link to that conversation; it measures accumulated participation, not simultaneous execution. Unknown and auto-review identities remain in accounting but do not earn model-exploration credit. Volume badges use complete report counters; reasoning includes any inference already present in the report and is a subset of output. Dates are the earliest threshold crossings confirmable from eligible timestamped events. An earned badge can have an unconfirmed date; the UI preserves the badge and labels that date accordingly. Report schema 11 uses the version-4 parser cache and migrates compatible earlier caches.

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

Artifacts are written to `dist/`. The app icon is generated at all standard macOS resolutions from `scripts/render_icon.swift` during every build; `assets/AppIcon.icns` is the checked-in preview asset.

See [the 0.3.7 review and verification notes](docs/QA-0.3.7.md) for the latest usability and regression coverage.

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
