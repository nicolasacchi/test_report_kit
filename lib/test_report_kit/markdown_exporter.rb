# frozen_string_literal: true

require "fileutils"
require "time"

module TestReportKit
  class MarkdownExporter
    def initialize(metrics:, diff_coverage:, config: TestReportKit.configuration)
      @metrics       = metrics
      @diff_coverage = diff_coverage
      @config        = config
    end

    def export
      output_path = File.join(@config.output_dir, "report.md")
      FileUtils.mkdir_p(@config.output_dir)
      File.write(output_path, build)
      output_path
    end

    def build
      @build ||= begin
        sections = []
        sections << header_section
        sections << summary_section
        sections << diff_coverage_section
        sections << low_coverage_section
        sections << factory_section
        sections << action_items_section
        sections.compact.join("\n\n---\n\n")
      end
    end

    private

    def header_section
      "# Test Report: #{@config.resolved_project_name}\n\n" \
      "Generated: #{Time.now.iso8601}  \n" \
      "Branch: `#{branch}` | SHA: `#{sha}`"
    end

    def summary_section
      cov = @metrics[:overall_coverage]
      rspec = @metrics[:rspec_summary]
      lines = ["## Summary\n"]
      lines << "| Metric | Value |"
      lines << "|--------|-------|"
      if cov
        lines << "| Line Coverage | #{cov[:coverage_pct]}% (#{cov[:covered_lines]}/#{cov[:total_lines]}) |"
        lines << "| Branch Coverage | #{cov[:branch_coverage_pct]}% |"
      end
      if rspec
        lines << "| Duration | #{rspec[:duration_formatted]} |"
        lines << "| Examples | #{rspec[:example_count]} (#{rspec[:failure_count]} failures, #{rspec[:pending_count]} pending) |"
      end
      if @diff_coverage
        lines << "| Diff Coverage | #{@diff_coverage.diff_coverage_pct || 'N/A'}% (#{@diff_coverage.covered_changed_lines}/#{@diff_coverage.executable_changed_lines} changed lines) |"
        lines << "| Diff Threshold | #{@diff_coverage.threshold}% — #{@diff_coverage.passed ? 'PASS' : 'FAIL'} |"
      end
      factory = @metrics[:factory_health]
      lines << "| Factory Creates | #{factory[:total_count]} |" if factory
      lines.join("\n")
    end

    def diff_coverage_section
      return nil unless @diff_coverage

      lines = ["## Diff Coverage Details\n"]
      @diff_coverage.files.each do |f|
        status = f.not_loaded ? "NOT LOADED BY TESTS" : "#{f.diff_coverage_pct}%"
        lines << "### `#{f.path}` — #{status}\n"

        if f.not_loaded
          lines << "> This file was never loaded during the test suite. All #{f.uncovered_lines.size} changed lines are uncovered.\n"
          next
        end

        next unless f.uncovered_lines.any?

        lines << "Uncovered lines: `#{f.uncovered_lines.join(', ')}`\n"
        lines << "```ruby"
        f.uncovered_content.each do |entry|
          next if entry[:type] == :gap
          prefix = entry[:type] == :uncovered ? "- " : "  "
          lines << "#{prefix}#{entry[:line]}: #{entry[:content]}"
        end
        lines << "```"
      end
      lines.join("\n")
    end

    def low_coverage_section
      files = (@metrics[:file_coverage] || []).select { |f| f[:coverage_pct] < 80 }
      return nil if files.empty?

      lines = ["## Files Below 80% Coverage\n"]
      lines << "| File | Coverage | Missed | Churn | Risk |"
      lines << "|------|----------|--------|-------|------|"
      files.each do |f|
        lines << "| `#{f[:path]}` | #{f[:coverage_pct]}% | #{f[:missed_lines]} | #{f[:churn]} | #{f[:risk_score]} |"
      end
      lines.join("\n")
    end

    def factory_section
      health = @metrics[:factory_health]
      return nil unless health && health[:suggestions]&.any?

      lines = ["## Factory Optimization Suggestions\n"]
      health[:suggestions].each do |s|
        lines << "- **#{s[:severity]}**: #{s[:message]}"
      end
      lines.join("\n")
    end

    def action_items_section
      items = []

      if @diff_coverage&.passed == false
        items << "- [ ] **Diff coverage below threshold** (#{@diff_coverage.diff_coverage_pct}% < #{@diff_coverage.threshold}%)"
        @diff_coverage.files.select { |f| f.uncovered_lines.any? }.each do |f|
          items << "  - `#{f.path}`: #{f.uncovered_lines.size} uncovered lines"
        end
      end

      insights = @metrics[:insights] || {}
      (insights[:high_risk] || []).first(5).each do |f|
        items << "- [ ] **High-risk** `#{f[:path]}`: #{f[:coverage_pct]}% coverage, #{f[:churn]} commits"
      end
      (insights[:untested_hot_paths] || []).first(3).each do |f|
        items << "- [ ] **Untested hot path** `#{f[:path]}`: #{f[:churn]} commits, 0% coverage"
      end

      return nil if items.empty?
      (["## Action Items\n"] + items).join("\n")
    end

    def branch
      ENV.fetch("TEST_REPORT_BRANCH", `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip)
    end

    def sha
      ENV.fetch("TEST_REPORT_SHA", `git rev-parse --short HEAD 2>/dev/null`.strip)
    end
  end
end
