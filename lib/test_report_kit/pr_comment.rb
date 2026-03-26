# frozen_string_literal: true

require "json"

module TestReportKit
  class PRComment
    def self.format(summary_path)
      new(summary_path).to_markdown
    end

    def initialize(summary_path)
      @summary = JSON.parse(File.read(summary_path))
    end

    def to_markdown
      lines = []
      lines << "## Test Report"
      lines << ""
      lines << diff_coverage_line
      lines << ""
      lines << "| Metric | Value |"
      lines << "|--------|-------|"
      lines << "| Coverage | #{s('coverage_pct')}%#{delta_badge} |" if s("coverage_pct")
      lines << "| Branch Coverage | #{s('branch_coverage_pct')}% |" if s("branch_coverage_pct")
      lines << "| Duration | #{s('duration_formatted')} |" if s("duration_formatted")
      lines << "| Examples | #{s('total_examples')} (#{s('failed_examples')} failures) |" if s("total_examples")
      lines << "| Factory Creates | #{s('total_factory_creates')} |" if s("total_factory_creates")
      lines << "| Peak Memory | #{s('peak_memory_mb')} MB |" if s("peak_memory_mb")
      lines << ""

      if risks.any?
        lines << "**Top Risks:**"
        risks.first(3).each do |r|
          lines << "- `#{r['file']}` — #{r['coverage']}% coverage, #{r['churn']} commits"
        end
        lines << ""
      end

      if uncovered_files.any?
        lines << "**Uncovered Changed Files:**"
        uncovered_files.each do |f|
          lines << "- `#{f['file']}` — #{f['diff_coverage_pct']}% (#{f['uncovered_count']} lines uncovered)"
        end
        lines << ""
      end

      lines.join("\n")
    end

    private

    def s(key)
      @summary[key]
    end

    def diff_coverage_line
      pct = s("diff_coverage_pct")
      threshold = s("diff_coverage_threshold")
      passed = s("diff_coverage_passed")

      if pct.nil?
        "Diff coverage: N/A (not a feature branch)"
      else
        icon = passed ? "PASS" : "FAIL"
        covered = s("diff_covered_lines") || 0
        total = s("diff_executable_lines") || 0
        "**Diff Coverage: #{pct}%** (#{icon}) — #{covered}/#{total} changed lines covered (threshold: #{threshold}%)"
      end
    end

    def delta_badge
      delta = s("coverage_delta")
      return "" unless delta
      " (#{delta})"
    end

    def risks
      s("top_risks") || []
    end

    def uncovered_files
      s("diff_uncovered_files") || []
    end
  end
end
