# test_report_kit

RSpec coverage + profiling HTML dashboard. Reads SimpleCov and test-prof output files, generates a single self-contained HTML report.

**Live demos:** [passing](https://nicolasacchi.github.io/test_report_kit_demo/main/) | [diff coverage](https://nicolasacchi.github.io/test_report_kit_demo/feature-add-services/) | [failures](https://nicolasacchi.github.io/test_report_kit_demo/feature-failing-tests/) | [parallel](https://nicolasacchi.github.io/test_report_kit_demo/feature-parallel-tests/)

## Setup

### From GitHub

```ruby
# Gemfile
group :test do
  gem "test_report_kit", github: "nicolasacchi/test_report_kit", branch: "main"
  gem "simplecov", require: false
  gem "simplecov-json", require: false
  gem "test-prof", "~> 1.0"
end
```

### From local path

If you have the gem checked out locally (e.g. at `~/projects/test_report_kit`):

```ruby
# Gemfile
group :test do
  gem "test_report_kit", path: "~/projects/test_report_kit"
  gem "simplecov", require: false
  gem "simplecov-json", require: false
  gem "test-prof", "~> 1.0"
end
```

### Configure

```ruby
# config/initializers/test_report_kit.rb
if Rails.env.test?
  TestReportKit.configure do |config|
    config.project_name = "my_app"
    config.github_url = "https://github.com/org/repo"
  end
end
```

### Run

```bash
bundle exec rake test_report:full
open tmp/test_report/index.html
```

Auto-integrates via Railtie. No manual require needed.

For non-Rails projects, add to your Rakefile:

```ruby
require "test_report_kit"
load "tasks/test_report_kit.rake"
```

## Rake Tasks

| Task | Description |
|------|-------------|
| `test_report:full` | Run tests with coverage + profiling, generate report |
| `test_report:coverage` | Coverage only (no profiling) |
| `test_report:profile` | Profiling only (no coverage) |
| `test_report:generate` | Re-generate from existing JSON (no test run) |
| `test_report:merge[pattern]` | Merge parallel CI artifacts and generate report |

## Dashboard Tabs

| Tab | Content |
|-----|---------|
| Diff Coverage | Changed lines coverage with uncovered code viewer |
| Failures | Failed tests with error details + source (conditional) |
| Coverage | Per-file coverage with inline line viewer (click to expand) |
| Performance | Time distribution, file grouping, slowest tests, RSpecDissect, EventProf |
| Factory Health | FactoryBot usage, cascade analysis, optimization suggestions |
| Insights | High-risk files, over-tested, false security, untested hot paths |
| Parallel | Per-node stats, efficiency %, duration balance (conditional, after merge) |

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
| `fail_on_coverage` | `false` | Exit 1 if below `coverage_threshold` |
| `fail_on_diff_coverage` | `false` | Exit 1 if below `diff_coverage_threshold` |

## Output Files

All written to `output_dir` (default `tmp/test_report/`):

| File | Purpose |
|------|---------|
| `index.html` | Dashboard (self-contained, open in browser) |
| `summary.json` | CI consumption (PR comments, threshold gates) |
| `report.md` | Markdown report with action items (for AI/code review tools) |
| `resource_usage.json` | Peak memory (MB), CPU time (user/system seconds) |
| `rspec_results.json` | Raw RSpec JSON output |
| `factory_prof.json` | FactoryProf data |
| `event_prof.json` | EventProf data |
| `rspec_dissect.json` | RSpecDissect data |
| `git_churn.json` | Per-file commit counts (last N days) |

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

See [parallel demo](https://nicolasacchi.github.io/test_report_kit_demo/feature-parallel-tests/).

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

## Trend Tracking (v0.2.0)

The Runner automatically records key metrics after every `test_report:full` run to `trend_history.json`. After 2+ runs, a coverage trend sparkline chart appears below the summary cards.

Each entry records: coverage %, branch coverage, duration, example count, failures, factory creates, peak memory.

Keeps the last 30 entries. In CI, persist `trend_history.json` between runs (e.g. download from previous artifact or S3) to build history over time.

**[Live demo](https://nicolasacchi.github.io/test_report_kit_demo/feature-v0.2.0-demo/)** — shows trend chart with 4 data points.

## PR Comment Helper (v0.2.0)

Generate a formatted markdown comment from `summary.json`:

```ruby
require "test_report_kit/pr_comment"
markdown = TestReportKit::PRComment.format("tmp/test_report/summary.json")
```

Use in GitHub Actions to post a PR comment:

```yaml
- name: Post PR comment
  if: github.event_name == 'pull_request'
  uses: actions/github-script@v7
  with:
    script: |
      const fs = require('fs');
      // Read the pre-generated pr_comment.md (generated in a prior step)
      const body = fs.readFileSync('tmp/test_report/pr_comment.md', 'utf8');
      const {data:comments} = await github.rest.issues.listComments({
        owner: context.repo.owner, repo: context.repo.repo,
        issue_number: context.issue.number
      });
      const ex = comments.find(c => c.body?.includes('Test Report'));
      const p = {owner: context.repo.owner, repo: context.repo.repo, body};
      if (ex) await github.rest.issues.updateComment({...p, comment_id: ex.id});
      else await github.rest.issues.createComment({...p, issue_number: context.issue.number});
```

Generate the markdown in a prior step:

```yaml
- name: Generate PR comment
  run: |
    bundle exec ruby -e "
      require 'test_report_kit/pr_comment'
      File.write('tmp/test_report/pr_comment.md',
        TestReportKit::PRComment.format('tmp/test_report/summary.json'))
    "
```

Output includes: diff coverage badge, coverage/duration/examples table, top risks, uncovered files.

## Development

```bash
git clone https://github.com/nicolasacchi/test_report_kit.git
cd test_report_kit
docker compose build
docker compose run --rm gem bundle exec rspec   # 87 specs
```

MIT License
