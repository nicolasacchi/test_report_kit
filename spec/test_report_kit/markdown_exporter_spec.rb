# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/diff_coverage"
require "test_report_kit/markdown_exporter"
require "tmpdir"
require "fileutils"

RSpec.describe TestReportKit::MarkdownExporter do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.output_dir = tmpdir
      c.project_name = "test_app"
    end
    TestReportKit.configuration
  end

  let(:metrics) do
    {
      overall_coverage: { total_lines: 100, covered_lines: 70, missed_lines: 30, coverage_pct: 70.0, branch_coverage_pct: 55.0 },
      rspec_summary: { duration_seconds: 10.5, duration_formatted: "10s", example_count: 50, failure_count: 0, pending_count: 2 },
      file_coverage: [
        { path: "app/services/cart.rb", coverage_pct: 45.0, missed_lines: 20, churn: 10, risk_score: 550 },
        { path: "app/models/order.rb", coverage_pct: 90.0, missed_lines: 3, churn: 2, risk_score: 20 }
      ],
      factory_health: { total_count: 500, suggestions: [{ severity: "high", factory: "order", message: "cascade ratio 5x" }] },
      risk_scores: [{ path: "app/services/cart.rb", coverage_pct: 45.0, churn: 10, risk_score: 550 }],
      insights: {
        high_risk: [{ path: "app/services/cart.rb", coverage_pct: 45.0, churn: 10 }],
        untested_hot_paths: [{ path: "app/services/pricing.rb", churn: 15 }],
        over_tested: [], false_security: []
      },
      slowest_tests: []
    }
  end

  let(:diff_coverage) do
    TestReportKit::DiffCoverage::Result.new(
      base_branch: "main", base_sha: "abc", head_sha: "def",
      total_changed_lines: 10, executable_changed_lines: 8,
      covered_changed_lines: 5, uncovered_changed_lines: 3,
      diff_coverage_pct: 62.5, threshold: 90, passed: false,
      files: [
        TestReportKit::DiffCoverage::FileCoverage.new(
          path: "app/services/cart.rb", changed_lines: [1, 2, 3],
          covered_lines: [1], uncovered_lines: [2, 3], non_executable_lines: [],
          diff_coverage_pct: 33.3, not_loaded: false,
          uncovered_content: [
            { type: :context, line: 1, content: "  def optimize" },
            { type: :uncovered, line: 2, content: "    raise 'error'" },
            { type: :uncovered, line: 3, content: "  end" }
          ]
        )
      ]
    )
  end

  let(:exporter) { described_class.new(metrics: metrics, diff_coverage: diff_coverage, config: config) }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#export" do
    it "creates report.md" do
      path = exporter.export
      expect(File.exist?(path)).to be true
      expect(path).to end_with("report.md")
    end

    it "includes summary stats" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("70.0%")
      expect(md).to include("50")
    end

    it "includes diff coverage details" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("62.5%")
      expect(md).to include("cart.rb")
      expect(md).to include("raise 'error'")
    end

    it "includes action items" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("Action Items")
      expect(md).to include("Diff coverage below threshold")
      expect(md).to include("Untested hot path")
    end

    it "includes low coverage files" do
      exporter.export
      md = File.read(File.join(tmpdir, "report.md"))
      expect(md).to include("Below 80%")
      expect(md).to include("cart.rb")
      # 90% file should NOT be in "below 80%" section
      expect(md).not_to include("| `app/models/order.rb`")
    end
  end
end
