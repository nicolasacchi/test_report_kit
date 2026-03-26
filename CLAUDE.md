# test_report_kit

A Ruby gem that generates a unified RSpec coverage + profiling HTML dashboard. Replaces Codecov with a free, self-hosted solution.

**Repos:**
- Gem: github.com/nicolasacchi/test_report_kit
- Demo: github.com/nicolasacchi/test_report_kit_demo
- Live: nicolasacchi.github.io/test_report_kit_demo/

## Running Tests

```bash
docker compose run --rm gem bundle exec rspec          # full suite (81 specs)
docker compose run --rm gem bundle exec rspec spec/test_report_kit/diff_coverage_spec.rb  # single file
docker compose build                                    # rebuild after Gemfile changes
```

## Architecture

### Data Flow

```
rake test_report:full
  → Runner.run!
    → run_rspec (shells out to `bundle exec rspec` with ENV vars)
      → FPROF=json, EVENT_PROF=factory.create, RD_PROF=1
      → captures stdout → splits EventProf/RSpecDissect text → parses to JSON
      → locates FactoryProf test-prof.result*.json → copies to output_dir
      → measures peak memory (RSS) + CPU time → saves resource_usage.json
    → compute_git_churn (git log --since)
    → DataLoader.load_all (reads all JSON files)
    → DiffCoverage.call (git diff + SimpleCov cross-reference)
    → MetricsCalculator.call (risk scores, insights, distributions)
    → Generator.generate (ERB → single index.html)
    → SummaryExporter.export (summary.json for CI)
    → MarkdownExporter.export (report.md for Claude Code)
```

### Key Design Decisions

- **Zero runtime deps** on simplecov or test-prof. The gem reads their output files. The host app manages those gems.
- **Single HTML file** with all CSS/JS inlined. No external dependencies except Google Fonts (graceful fallback).
- **ERB templates** rendered via Ruby's `ERB` directly (not Rails). Templates access generator methods via `binding`.
- **Railtie** auto-loads rake tasks when the gem is in a Rails Gemfile. No manual require needed.

## File Layout

```
lib/
  test_report_kit.rb              # Entry point, configure block, autoloads
  test_report_kit/
    version.rb                    # VERSION constant
    configuration.rb              # All config options with defaults
    railtie.rb                    # Rails::Railtie for rake task loading
    runner.rb                     # Orchestrator: runs tests, captures output, generates report
    diff_coverage.rb              # Git diff parser + SimpleCov cross-reference
    data_loader.rb                # Reads all JSON/text inputs
    metrics_calculator.rb         # Risk scores, insights, test distribution, factory stats
    generator.rb                  # ERB renderer + all template helpers
    summary_exporter.rb           # summary.json writer (with delta from previous run)
    markdown_exporter.rb          # report.md writer (for Claude Code/AI consumption)
    templates/
      dashboard.html.erb          # Main HTML shell: head, CSS, tabs, JS
      _summary_cards.html.erb     # 5 summary cards + resource stats bar
      _tab_diff_coverage.html.erb # Diff coverage: per-file table + uncovered code viewer
      _tab_failures.html.erb      # Failed tests (conditional tab)
      _tab_coverage.html.erb      # File coverage with inline Codecov-style viewer
      _tab_performance.html.erb   # Time dist, file grouping, slowest tests, RSpecDissect, EventProf
      _tab_factories.html.erb     # Factory ranking + expandable details + suggestions
      _tab_insights.html.erb      # High-risk, over-tested, false security, untested hot paths
  tasks/
    test_report_kit.rake          # Rake task definitions (full, coverage, profile, generate)
spec/
  fixtures/                       # Sample JSON files for testing
  test_report_kit/                # Per-class specs
```

## Configuration

```ruby
# In host app: config/initializers/test_report_kit.rb
TestReportKit.configure do |config|
  config.project_name             = "my_app"           # Dashboard header
  config.output_dir               = "tmp/test_report"  # Report output directory
  config.diff_base_branch         = "main"             # Git diff base for diff coverage
  config.coverage_threshold       = 80                 # Overall coverage gate (%)
  config.diff_coverage_threshold  = 90                 # Diff coverage gate (%)
  config.churn_days               = 90                 # Git churn lookback (days)
  config.slow_test_threshold      = 5.0                # Flag tests slower than this (seconds)
  config.factory_cascade_threshold = 10                # Flag factories with cascade above this
  config.github_url               = "https://github.com/org/repo"  # Enables source links
  config.event_prof_event         = "factory.create"   # EventProf event to track
  config.profilers                = %i[factory_prof rspec_dissect event_prof]  # Which profilers
end
```

## Generator Helpers

Key methods available in templates (via `generator.rb`):

| Helper | Purpose |
|--------|---------|
| `h(text)` | HTML escape |
| `file_link(path, line:)` | Plain text path + GitHub icon link |
| `gh_link(path, line:)` | Just the GitHub icon `<a>` tag |
| `factory_file_link(name)` | GitHub link to factory definition file |
| `highlight_ruby(code)` | Syntax-highlighted Ruby (StringScanner tokenizer) |
| `build_test_source(file, line)` | Extract test block source with smart `end` detection |
| `build_file_line_data(path)` | Per-line coverage data for inline file viewer |
| `coverage_color(pct)` | Returns CSS color var for coverage percentage |
| `risk_color(score)` / `risk_bg(score)` | Color for risk score badges |
| `format_number(n)` | Number with comma separators |

## Dashboard Tabs

### 1. Diff Coverage (`_tab_diff_coverage.html.erb`)
- Shows on feature branches only (nil on base branch)
- Per-file table sorted by coverage ascending (worst first)
- Uncovered code viewer with syntax highlighting and context lines
- Summary stats: files changed, 100% covered, partially covered, not loaded

### 2. Failures (`_tab_failures.html.erb`)
- Only appears when `failed_tests` is not empty
- Red badge count on tab header
- Expandable rows: error class, message, backtrace + test source code
- "All tests passed" empty state when no failures

### 3. Coverage (`_tab_coverage.html.erb`)
- File table with line/branch coverage, churn, risk scores
- Click any row → inline Codecov-style line viewer (green/red/neutral per line)
- Execution counts (`1x`, `0x`) per line
- Clickable line numbers linking to GitHub
- "Hide 100% coverage" checkbox

### 4. Performance (`_tab_performance.html.erb`)
- Time distribution bar chart (buckets: <0.01s to >1s)
- Time by spec file (grouped, sorted by total time)
- Slowest examples (top 20, expandable with test source)
- RSpecDissect: setup vs example time with stacked bars
- EventProf: event counts per suite

### 5. Factory Health (`_tab_factories.html.erb`)
- Factory ranking table (creates, top-level, cascade ratio, time)
- Expandable detail: share of total, dependency inference, optimization potential
- GitHub icon linking to factory definition file
- Auto-generated optimization suggestions

### 6. Insights (`_tab_insights.html.erb`)
- High-Risk Files: churn > 5 AND coverage < 70%
- Over-Tested Files: coverage > 90% AND test time > 10s
- False Security: >70% of test time in hooks
- Untested Hot Paths: churn > 10 AND coverage < 40%

## Conventions

- **Frozen string literals** in all Ruby files
- **ERB trim mode** `-` for clean output
- **CSS variables** for all colors (defined in dashboard.html.erb `:root`)
- **No external JS/CSS** — everything inline for self-contained HTML
- **Graceful degradation** — missing data shows empty states, never crashes
- **GitHub links** via `gh_link()` helper everywhere, never raw `<a>` tags for file paths
- **Expandable rows** pattern: `.xxx-row` + `.xxx-detail` + JS click handler with `e.target.closest('a')` guard

## Gotchas

1. **highlight_ruby** uses `StringScanner` single-pass tokenizer. Comments (`#`) matched FIRST to prevent matching `#hex` in CSS color strings.
2. **SimpleCov coverage arrays** are 0-indexed: `coverage[0]` = line 1. `null` = non-executable, `0` = uncovered, `>0` = covered.
3. **split_profiler_output** regex must use specific boundaries (`\n\nRSpecDissect`, `\n\nFinished in`) — generic `\n\n[A-Z]` truncates because `\n\nTotal` matches immediately after the header.
4. **resolve_base_ref** tries local branch then `origin/` prefix for CI where only the current branch is checked out locally.
5. **build_test_source** uses indentation-aware `end` detection — stops at `end` matching the `it` block's indent level.
6. **gh-pages deploy** uses concurrency group to serialize deploys from different branches. Each branch deploys to its own subdirectory.
7. **FactoryProf** writes to `tmp/test_prof/test-prof.result.json` (not `factory_prof.json`). The DataLoader globs for `test-prof.result*.json`.
8. **EventProf/RSpecDissect** output text to stdout. The Runner captures stdout to a file, splits by section headers, then parses text→JSON.

## Demo App

The demo app (`test_report_kit_demo`) has deliberately varying test quality:

| Component | Coverage | Design Purpose |
|-----------|----------|---------------|
| Product | >90% | Well-tested model |
| Pharmacy | >90% | Well-tested model |
| Order | ~65% | cancel!/cod? deliberately untested |
| CartOptimizer | ~45% | Only happy path tested |
| PricingEngine | ~29% | Poorly tested (untested hot path in insights) |
| PaymentService | ~55% | refund!/timeout not tested |
| ShippingCalculator | ~95% | Fully tested |

### Branches
- `main` — all passing, full data on all tabs
- `feature/add-services` — diff coverage data (modifies existing files)
- `feature/failing-tests` — 4 intentional failures with error details

### Git History
20+ backdated commits creating realistic churn:
- pricing_engine.rb: 11 commits → triggers "Untested Hot Paths" insight
- cart_optimizer.rb: 6 commits → triggers "High-Risk Files" insight
- order.rb: 6 commits → triggers "High-Risk Files" insight

### CI/CD
GitHub Actions workflow: test → deploy to GitHub Pages (per-branch subdirectories with landing page).
