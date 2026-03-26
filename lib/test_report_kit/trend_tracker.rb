# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module TestReportKit
  class TrendTracker
    MAX_ENTRIES = 30

    def initialize(config: TestReportKit.configuration)
      @config = config
    end

    def record(summary_path)
      return unless File.exist?(summary_path)

      summary = JSON.parse(File.read(summary_path))
      entry = {
        "timestamp" => Time.now.iso8601,
        "branch" => summary["branch"],
        "sha" => summary["sha"],
        "coverage_pct" => summary["coverage_pct"],
        "branch_coverage_pct" => summary["branch_coverage_pct"],
        "diff_coverage_pct" => summary["diff_coverage_pct"],
        "duration_seconds" => summary["duration_seconds"],
        "total_examples" => summary["total_examples"],
        "failed_examples" => summary["failed_examples"],
        "total_factory_creates" => summary["total_factory_creates"],
        "peak_memory_mb" => summary["peak_memory_mb"]
      }

      history = load_history
      history << entry
      history = history.last(MAX_ENTRIES)
      save_history(history)
      history
    end

    def load_history
      path = history_path
      return [] unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      []
    end

    private

    def save_history(history)
      FileUtils.mkdir_p(@config.output_dir)
      File.write(history_path, JSON.pretty_generate(history))
    end

    def history_path
      File.join(@config.output_dir, "trend_history.json")
    end
  end
end
