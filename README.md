# test_report_kit

RSpec coverage + profiling HTML dashboard. Reads SimpleCov and test-prof output files, generates a single self-contained HTML report.

**Live demos:** [passing](https://nicolasacchi.github.io/test_report_kit_demo/main/) | [diff coverage](https://nicolasacchi.github.io/test_report_kit_demo/feature-add-services/) | [failures](https://nicolasacchi.github.io/test_report_kit_demo/feature-failing-tests/)

## Setup

```ruby
# Gemfile
group :test do
  gem "test_report_kit", github: "nicolasacchi/test_report_kit", branch: "main"
  gem "simplecov", require: false
  gem "simplecov-json", require: false
  gem "test-prof", "~> 1.0"
end
```

```ruby
# config/initializers/test_report_kit.rb
if Rails.env.test?
  TestReportKit.configure do |config|
    config.project_name = "my_app"
    config.github_url = "https://github.com/org/repo"
  end
end
```

```bash
bundle exec rake test_report:full
open tmp/test_report/index.html
```

Auto-integrates via Railtie. No manual require needed.

## Rake Tasks

| Task | Description |
|------|-------------|
| `test_report:full` | Run tests with coverage + profiling, generate report |
| `test_report:coverage` | Coverage only (no profiling) |
| `test_report:profile` | Profiling only (no coverage) |
| `test_report:generate` | Re-generate from existing JSON (no test run) |

## Dashboard Tabs

| Tab | Content |
|-----|---------|
| Diff Coverage | Changed lines coverage with uncovered code viewer |
| Failures | Failed tests with error details + source (conditional) |
| Coverage | Per-file coverage with inline line viewer (click to expand) |
| Performance | Time distribution, file grouping, slowest tests, RSpecDissect, EventProf |
| Factory Health | FactoryBot usage, cascade analysis, optimization suggestions |
| Insights | High-risk files, over-tested, false security, untested hot paths |

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `project_name` | dir name | Dashboard header |
| `output_dir` | `tmp/test_report` | Output directory |
| `diff_base_branch` | `main` | Git diff base |
| `coverage_threshold` | `80` | Coverage gate (%) |
| `diff_coverage_threshold` | `90` | Diff coverage gate (%) |
| `churn_days` | `90` | Git churn lookback (days) |
| `slow_test_threshold` | `5.0` | Slow test flag (seconds) |
| `github_url` | `nil` | Enables source links |
| `event_prof_event` | `factory.create` | EventProf event |
| `profilers` | `[:factory_prof, :rspec_dissect, :event_prof]` | Enabled profilers |

## Output Files

| File | Purpose |
|------|---------|
| `index.html` | Dashboard (self-contained) |
| `summary.json` | CI consumption (PR comments, threshold gates) |
| `report.md` | Markdown report (for AI/code review tools) |
| `resource_usage.json` | Peak memory, CPU time |

## CI Example

See [demo workflow](https://github.com/nicolasacchi/test_report_kit_demo/blob/main/.github/workflows/test-report.yml) for GitHub Actions with PR comments and Pages deployment.

## Parallel CI

For matrix-based parallel test runs across multiple containers:

```yaml
jobs:
  test:
    strategy:
      matrix:
        include:
          - node: 0
            specs: "spec/models/ spec/jobs/"
          - node: 1
            specs: "spec/services/"
    steps:
      - run: bundle exec rake test_report:full
        env:
          TEST_ENV_NUMBER: ${{ matrix.node }}
          TEST_REPORT_SPECS: ${{ matrix.specs }}
      - uses: actions/upload-artifact@v4
        with:
          name: test-results-${{ matrix.node }}
          include-hidden-files: true  # required for .resultset.json
          path: |
            coverage/
            tmp/test_report/
            tmp/test_prof/

  report:
    needs: test
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: artifacts/
      - run: bundle exec rake "test_report:merge[artifacts/test-results-*]"
```

The merge task combines coverage, RSpec results, profiler data, and resource metrics from all nodes. The Parallel tab shows per-node breakdown and balance analysis.

See [parallel demo](https://nicolasacchi.github.io/test_report_kit_demo/feature-parallel-tests/) for a live example.

## Architecture

Zero runtime deps on simplecov/test-prof. Reads their output files after RSpec completes.

```
Runner → shells out to rspec with ENV vars (FPROF, EVENT_PROF, RD_PROF)
       → DataLoader reads all JSON outputs
       → DiffCoverage parses git diff + cross-refs SimpleCov
       → MetricsCalculator computes risk scores + insights
       → Generator renders ERB templates → single HTML
       → SummaryExporter writes summary.json
       → MarkdownExporter writes report.md
```

## Development

```bash
docker compose build
docker compose run --rm gem bundle exec rspec   # 81 specs
```

MIT License
