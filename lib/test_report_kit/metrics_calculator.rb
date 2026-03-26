# frozen_string_literal: true

module TestReportKit
  class MetricsCalculator
    def initialize(simplecov_data:, rspec_data:, factory_prof_data:,
                   event_prof_data:, rspec_dissect_data:, git_churn_data:,
                   diff_coverage:, config: TestReportKit.configuration)
      @simplecov     = simplecov_data
      @rspec         = rspec_data
      @factory_prof  = factory_prof_data
      @event_prof    = event_prof_data
      @rspec_dissect = rspec_dissect_data
      @git_churn     = git_churn_data
      @diff_coverage = diff_coverage
      @config        = config
    end

    def call
      {
        overall_coverage: overall_coverage,
        file_coverage: file_coverage_list,
        rspec_summary: rspec_summary,
        slowest_tests: slowest_tests,
        factory_health: factory_health,
        risk_scores: risk_scores,
        insights: insights
      }
    end

    private

    # ── Overall coverage ──

    def overall_coverage
      return nil unless @simplecov

      total = 0
      covered = 0
      branch_total = 0
      branch_covered = 0

      @simplecov.each_value do |data|
        lines = data.is_a?(Hash) ? data["lines"] : data
        (lines || []).each do |count|
          next if count.nil?
          total += 1
          covered += 1 if count > 0
        end

        branches = data.is_a?(Hash) ? data.fetch("branches", {}) : {}
        branches.each_value do |branch_data|
          branch_data.each_value do |count|
            branch_total += 1
            branch_covered += 1 if count > 0
          end
        end
      end

      {
        total_lines: total,
        covered_lines: covered,
        missed_lines: total - covered,
        coverage_pct: total > 0 ? (covered.to_f / total * 100).round(1) : 0.0,
        branch_total: branch_total,
        branch_covered: branch_covered,
        branch_coverage_pct: branch_total > 0 ? (branch_covered.to_f / branch_total * 100).round(1) : 0.0
      }
    end

    # ── Per-file coverage ──

    def file_coverage_list
      return [] unless @simplecov

      churn_files = @git_churn&.dig("files") || {}

      @simplecov.map do |abs_path, data|
        lines = data.is_a?(Hash) ? data["lines"] : data
        relative = strip_to_relative(abs_path)

        total = 0
        covered = 0
        (lines || []).each do |count|
          next if count.nil?
          total += 1
          covered += 1 if count > 0
        end

        cov_pct = total > 0 ? (covered.to_f / total * 100).round(1) : 0.0
        churn = churn_files[relative] || 0
        risk = (churn * (100 - cov_pct)).round(0)

        branches = data.is_a?(Hash) ? data.fetch("branches", {}) : {}
        b_total = 0
        b_covered = 0
        branches.each_value do |branch_data|
          branch_data.each_value do |count|
            b_total += 1
            b_covered += 1 if count > 0
          end
        end
        branch_pct = b_total > 0 ? (b_covered.to_f / b_total * 100).round(1) : nil

        {
          path: relative,
          total_lines: total,
          covered_lines: covered,
          missed_lines: total - covered,
          coverage_pct: cov_pct,
          branch_coverage_pct: branch_pct,
          churn: churn,
          risk_score: risk
        }
      end.sort_by { |f| -f[:risk_score] }
    end

    # ── RSpec summary ──

    def rspec_summary
      return nil unless @rspec

      summary = @rspec["summary"] || {}
      {
        duration_seconds: summary["duration"],
        duration_formatted: format_duration(summary["duration"]),
        example_count: summary["example_count"],
        failure_count: summary["failure_count"],
        pending_count: summary["pending_count"]
      }
    end

    # ── Slowest tests ──

    def slowest_tests
      return [] unless @rspec && @rspec["examples"]

      @rspec["examples"]
        .select { |e| e["run_time"] && e["status"] != "pending" }
        .sort_by { |e| -e["run_time"] }
        .first(20)
        .map do |e|
          {
            description: e["full_description"] || e["description"],
            file: "#{e['file_path']}:#{e['line_number']}",
            duration: e["run_time"].round(2),
            status: e["status"],
            slow: e["run_time"] >= @config.slow_test_threshold
          }
        end
    end

    # ── Factory health ──

    def factory_health
      return nil unless @factory_prof

      stats = (@factory_prof["stats"] || []).map do |s|
        cascade_ratio = s["top_level_count"] > 0 ? (s["total_count"].to_f / s["top_level_count"]).round(1) : 0
        {
          name: s["name"],
          total_count: s["total_count"],
          top_level_count: s["top_level_count"],
          cascade_ratio: cascade_ratio,
          total_time: s["total_time"],
          top_level_time: s["top_level_time"]
        }
      end

      {
        total_count: @factory_prof["total_count"],
        total_top_level_count: @factory_prof["total_top_level_count"],
        total_time: @factory_prof["total_time"],
        total_uniq_factories: @factory_prof["total_uniq_factories"],
        stats: stats,
        suggestions: factory_suggestions(stats)
      }
    end

    def factory_suggestions(stats)
      suggestions = []
      stats.each do |s|
        if s[:cascade_ratio] >= 3 && s[:total_count] >= 100
          suggestions << {
            severity: s[:cascade_ratio] >= 5 ? "critical" : "high",
            factory: s[:name],
            message: "`:#{s[:name]}` has cascade ratio #{s[:cascade_ratio]}x " \
                     "(#{s[:total_count]} total / #{s[:top_level_count]} top-level). " \
                     "Consider using `build_stubbed` or traits to reduce unnecessary associations."
          }
        end
        if s[:total_count] >= 500 && s[:cascade_ratio] < 2
          suggestions << {
            severity: "medium",
            factory: s[:name],
            message: "`:#{s[:name]}` is created #{s[:total_count]} times. " \
                     "Consider using `let_it_be` from test-prof to share across examples."
          }
        end
      end
      suggestions
    end

    # ── Risk scores ──

    def risk_scores
      file_coverage_list.select { |f| f[:risk_score] > 0 }
    end

    # ── Insights ──

    def insights
      {
        high_risk: high_risk_files,
        over_tested: over_tested_files,
        false_security: false_security_files,
        untested_hot_paths: untested_hot_paths
      }
    end

    def high_risk_files
      file_coverage_list.select { |f| f[:churn] > 5 && f[:coverage_pct] < 70 }
    end

    def over_tested_files
      return [] unless @rspec && @rspec["examples"]

      file_times = Hash.new(0.0)
      @rspec["examples"].each do |e|
        file_times[e["file_path"]] += (e["run_time"] || 0)
      end

      file_coverage_list.select do |f|
        spec_path = "./spec/#{f[:path].sub('app/', '').sub('.rb', '_spec.rb')}"
        f[:coverage_pct] > 90 && (file_times[spec_path] || 0) > 10
      end.map do |f|
        spec_path = "./spec/#{f[:path].sub('app/', '').sub('.rb', '_spec.rb')}"
        f.merge(total_test_time: (file_times[spec_path] || 0).round(1))
      end
    end

    def false_security_files
      return [] unless @rspec_dissect && @rspec_dissect["suites"]

      @rspec_dissect["suites"].filter_map do |suite|
        before_pct = suite["before_pct"] || 0
        let_pct = suite["let_pct"] || 0
        hook_pct = before_pct + let_pct
        next unless hook_pct > 70

        {
          location: suite["location"],
          description: suite["description"],
          total_time: suite["total_time"],
          hook_time: suite["before_time"],
          example_time: suite["example_time"],
          hook_pct: hook_pct.round(1)
        }
      end
    end

    def untested_hot_paths
      return [] unless @git_churn

      churn_files = @git_churn["files"] || {}
      coverage_map = file_coverage_list.each_with_object({}) { |f, h| h[f[:path]] = f[:coverage_pct] }

      churn_files.filter_map do |path, commits|
        cov = coverage_map[path]
        next unless commits > 10 && (cov.nil? || cov < 40)

        { path: path, churn: commits, coverage_pct: cov || 0.0 }
      end.sort_by { |f| -f[:churn] }
    end

    # ── Helpers ──

    def strip_to_relative(abs_path)
      abs_path.sub(%r{^#{Regexp.escape(@config.project_root)}/?}, "")
    end

    def format_duration(seconds)
      return "—" unless seconds

      mins = (seconds / 60).floor
      secs = (seconds % 60).floor
      mins > 0 ? "#{mins}m #{secs}s" : "#{secs}s"
    end
  end
end
