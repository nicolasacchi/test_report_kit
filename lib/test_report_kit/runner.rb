# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "data_loader"
require_relative "diff_coverage"
require_relative "metrics_calculator"
require_relative "generator"
require_relative "summary_exporter"
require_relative "markdown_exporter"
require_relative "trend_tracker"

module TestReportKit
  class Runner
    def initialize(config, mode: :full)
      @config = config
      @mode = mode
    end

    def run!
      case @mode
      when :full    then run_full
      when :coverage then run_coverage
      when :profile  then run_profile
      when :generate then run_generate
      else raise Error, "Unknown mode: #{@mode}"
      end
    end

    private

    def run_full    = run_pipeline(coverage: true, profiling: true)
    def run_coverage = run_pipeline(coverage: true, profiling: false)
    def run_profile  = run_pipeline(coverage: false, profiling: true)
    def run_generate = (generate_report; 0)

    def run_pipeline(coverage:, profiling:)
      validate_dependencies(require_simplecov: coverage, require_test_prof: profiling)
      setup_simplecov if coverage
      rspec_exit = run_rspec(profiling: profiling, coverage: coverage)
      compute_git_churn
      generate_report
      check_thresholds(rspec_exit)
    end

    def check_thresholds(rspec_exit)
      return rspec_exit unless rspec_exit == 0

      summary_path = File.join(@config.output_dir, "summary.json")
      return rspec_exit unless File.exist?(summary_path)

      summary = JSON.parse(File.read(summary_path))

      if @config.fail_on_coverage && summary["coverage_pct"]
        if summary["coverage_pct"] < @config.coverage_threshold
          warn "TestReportKit: Coverage #{summary['coverage_pct']}% is below threshold #{@config.coverage_threshold}%"
          return 1
        end
      end

      if @config.fail_on_diff_coverage && summary["diff_coverage_passed"] == false
        warn "TestReportKit: Diff coverage #{summary['diff_coverage_pct']}% is below threshold #{summary['diff_coverage_threshold']}%"
        return 1
      end

      rspec_exit
    rescue JSON::ParserError
      rspec_exit
    end

    # ── Pipeline steps ──

    def validate_dependencies(require_simplecov: true, require_test_prof: true)
      if require_simplecov
        begin
          Gem::Specification.find_by_name("simplecov")
        rescue Gem::MissingSpecError
          warn "TestReportKit: simplecov gem not found. Add it to your Gemfile's :test group."
        end
      end

      if require_test_prof
        begin
          Gem::Specification.find_by_name("test-prof")
        rescue Gem::MissingSpecError
          warn "TestReportKit: test-prof gem not found. Add it to your Gemfile's :test group."
        end
      end
    end

    def setup_simplecov
      # Check if the host app already configures SimpleCov
      spec_helper = File.join(@config.project_root, "spec", "spec_helper.rb")
      if File.exist?(spec_helper) && File.read(spec_helper).include?("SimpleCov")
        puts "TestReportKit: Using existing SimpleCov configuration from spec/spec_helper.rb"
        return
      end

      simplecov_file = File.join(@config.project_root, ".simplecov")
      if File.exist?(simplecov_file)
        puts "TestReportKit: Using existing SimpleCov configuration from .simplecov"
        return
      end

      # Generate SimpleCov init file
      init_path = File.join(@config.project_root, "tmp", "test_report_kit_simplecov_init.rb")
      FileUtils.mkdir_p(File.dirname(init_path))
      File.write(init_path, simplecov_init_content)
      @simplecov_init_path = init_path
      puts "TestReportKit: Generated SimpleCov configuration at #{init_path}"
    end

    def run_rspec(profiling:, coverage:)
      FileUtils.mkdir_p(@config.output_dir)

      env = {}
      if profiling && @config.profilers.include?(:factory_prof)
        env["FPROF"] = "json"
      end
      if profiling && @config.profilers.include?(:event_prof)
        env["EVENT_PROF"] = @config.event_prof_event
      end
      if profiling && @config.profilers.include?(:rspec_dissect)
        env["RD_PROF"] = "1"
      end

      rspec_json_path = File.join(@config.output_dir, "rspec_results.json")
      output_log = File.join(@config.output_dir, "test_output.log")

      cmd_parts = ["bundle", "exec", "rspec"]
      cmd_parts += ENV["TEST_REPORT_SPECS"].split if ENV["TEST_REPORT_SPECS"]
      cmd_parts += ["--require", @simplecov_init_path] if coverage && @simplecov_init_path
      cmd_parts += ["--format", "json", "--out", rspec_json_path]
      cmd_parts += ["--format", "progress"]

      puts "TestReportKit: Running RSpec..."
      start_cpu = Process.times
      pid = spawn(env, *cmd_parts, out: output_log, err: [:child, :out])
      Process.wait(pid)
      rspec_exit = $?.exitstatus
      end_cpu = Process.times

      save_resource_usage(start_cpu, end_cpu)

      if profiling
        split_profiler_output(output_log)
        locate_and_copy_factory_prof
        parse_event_prof_text(File.join(@config.output_dir, "event_prof_output.txt"))
        parse_rspec_dissect_text(File.join(@config.output_dir, "rspec_dissect_output.txt"))
      end

      puts "TestReportKit: RSpec finished with exit code #{rspec_exit}"
      rspec_exit
    end

    def compute_git_churn
      days = @config.churn_days
      cmd = "git log --since='#{days} days' --name-only --pretty=format:''"
      output = `#{cmd} 2>/dev/null`
      return unless $?.success?

      churn = Hash.new(0)
      output.each_line do |line|
        file = line.strip
        next if file.empty?
        churn[file] += 1
      end

      churn_path = File.join(@config.output_dir, "git_churn.json")
      FileUtils.mkdir_p(@config.output_dir)
      File.write(churn_path, JSON.pretty_generate({ days: days, files: churn }))
    end

    def generate_report
      loader = DataLoader.new(config: @config).load_all

      diff_coverage = nil
      if loader.simplecov_data
        dc = DiffCoverage.new(coverage_data: loader.simplecov_data, config: @config)
        diff_coverage = dc.call
      end

      metrics = MetricsCalculator.new(
        simplecov_data: loader.simplecov_data,
        rspec_data: loader.rspec_data,
        factory_prof_data: loader.factory_prof_data,
        event_prof_data: loader.event_prof_data,
        rspec_dissect_data: loader.rspec_dissect_data,
        git_churn_data: loader.git_churn_data,
        diff_coverage: diff_coverage,
        config: @config
      ).call

      report_path = Generator.new(
        metrics: metrics,
        diff_coverage: diff_coverage,
        data_loader: loader,
        config: @config
      ).generate

      summary_path = SummaryExporter.new(
        metrics: metrics,
        diff_coverage: diff_coverage,
        config: @config
      ).export

      md_path = MarkdownExporter.new(
        metrics: metrics,
        diff_coverage: diff_coverage,
        config: @config
      ).export

      puts "TestReportKit: Dashboard → #{report_path}"
      puts "TestReportKit: Summary  → #{summary_path}"
      puts "TestReportKit: Markdown → #{md_path}"

      TrendTracker.new(config: @config).record(summary_path)
    end

    # ── Resource usage ──

    def save_resource_usage(start_cpu, end_cpu)
      usage = {
        peak_memory_mb: current_rss_mb,
        cpu_user_seconds: (end_cpu.cutime - start_cpu.cutime + end_cpu.utime - start_cpu.utime).round(1),
        cpu_system_seconds: (end_cpu.cstime - start_cpu.cstime + end_cpu.stime - start_cpu.stime).round(1)
      }

      path = File.join(@config.output_dir, "resource_usage.json")
      File.write(path, JSON.pretty_generate(usage))
    rescue StandardError => e
      warn "TestReportKit: #{e.message}"
      nil
    end

    def current_rss_mb
      if File.exist?("/proc/self/status")
        match = File.read("/proc/self/status").match(/VmRSS:\s+(\d+)/)
        match ? match[1].to_i / 1024 : nil
      else
        `ps -o rss= -p #{Process.pid}`.strip.to_i / 1024
      end
    rescue StandardError => e
      warn "TestReportKit: #{e.message}"
      nil
    end

    # ── Helpers ──

    def split_profiler_output(log_path)
      return unless File.exist?(log_path)

      content = File.read(log_path)

      # Extract EventProf section (stop at RSpecDissect, Finished, or end)
      if (match = content.match(/EventProf results for .+?(?=\n\nRSpecDissect|\n\nFinished in|\n\n\d+ examples|\z)/m))
        File.write(File.join(@config.output_dir, "event_prof_output.txt"), match[0])
      end

      # Extract RSpecDissect section (stop at EventProf, Finished, or end)
      if (match = content.match(/RSpecDissect report.+?(?=\n\nEventProf|\n\nFinished in|\n\n\d+ examples|\z)/m))
        File.write(File.join(@config.output_dir, "rspec_dissect_output.txt"), match[0])
      end
    end

    def locate_and_copy_factory_prof
      glob = File.join(@config.project_root, "tmp", "test_prof", "test-prof.result*.json")
      source = Dir.glob(glob).max_by { |f| File.mtime(f) }
      return unless source

      dest = File.join(@config.output_dir, "factory_prof.json")
      FileUtils.cp(source, dest)
      puts "TestReportKit: Copied FactoryProf → #{dest}"
    end

    def parse_event_prof_text(text_path)
      return unless text_path && File.exist?(text_path)

      content = strip_ansi(File.read(text_path))
      event_match = content.match(/EventProf results for (.+)/)
      total_match = content.match(/Total time: ([\d:.]+) of ([\d:.]+) \(([\d.]+)%\)/)
      events_match = content.match(/Total events: (\d+)/)
      return unless event_match

      suites = []
      # Handle both en-dash and hyphen: description (location) – time (count / examples) of run_time (pct%)
      content.scan(/^(.+?) \((.+?)\) [\u2013\-] ([\d:.]+) \((\d+) \/ (\d+)\) of ([\d:.]+) \(([\d.]+)%\)/m) do
        suites << {
          "description" => $1.strip, "location" => $2, "time" => $3,
          "event_count" => $4.to_i, "example_count" => $5.to_i,
          "run_time" => $6, "percentage" => $7.to_f
        }
      end

      result = {
        "event" => event_match[1].strip,
        "total_time" => total_match&.[](1), "total_run_time" => total_match&.[](2),
        "total_percentage" => total_match&.[](3)&.to_f, "total_events" => events_match&.[](1)&.to_i || 0,
        "suites" => suites
      }

      json_path = File.join(@config.output_dir, "event_prof.json")
      File.write(json_path, JSON.pretty_generate(result))
      puts "TestReportKit: Parsed EventProf → #{json_path}"
    end

    def parse_rspec_dissect_text(text_path)
      return unless text_path && File.exist?(text_path)

      content = strip_ansi(File.read(text_path))
      total_match = content.match(/Total time: ([\d:.]+)/)

      suites = []
      # Pattern: description (location) – setup_time (pct%) of total_time (count)
      content.scan(/^(.+?) \((.+?)\) [\u2013\-] ([\d:.]+) \(([\d.]+)%\) of ([\d:.]+) \((\d+)\)/m) do
        total_secs = parse_duration($5)
        before_pct = $4.to_f
        before_secs = total_secs * before_pct / 100
        example_secs = total_secs - before_secs

        suites << {
          "description" => $1.strip, "location" => $2,
          "total_time" => $5, "example_count" => $6.to_i,
          "before_time" => format_duration_short(before_secs),
          "let_time" => "00:00.000",
          "example_time" => format_duration_short(example_secs),
          "before_pct" => before_pct.round(1),
          "let_pct" => 0.0,
          "example_pct" => (100 - before_pct).round(1)
        }
      end

      result = { "total_time" => total_match&.[](1), "suites" => suites }
      json_path = File.join(@config.output_dir, "rspec_dissect.json")
      File.write(json_path, JSON.pretty_generate(result))
      puts "TestReportKit: Parsed RSpecDissect → #{json_path}"
    end

    def strip_ansi(text)
      text.gsub(/\e\[\d+(?:;\d+)*m/, "")
    end

    def parse_duration(str)
      return 0.0 unless str
      parts = str.split(":")
      parts[-2].to_f * 60 + parts[-1].to_f
    end

    def format_duration_short(seconds)
      mins = (seconds / 60).floor
      secs = seconds % 60
      format("%02d:%06.3f", mins, secs)
    end

    def simplecov_init_content
      threshold = @config.coverage_threshold
      <<~RUBY
        # Auto-generated by TestReportKit — do not edit
        require 'simplecov'
        require 'simplecov-json'

        SimpleCov.command_name "RSpec-\#{ENV['TEST_ENV_NUMBER'] || 0}" if ENV['TEST_ENV_NUMBER']

        SimpleCov.start 'rails' do
          enable_coverage :branch

          add_filter '/spec/'
          add_filter '/config/'
          add_filter '/db/'
          add_filter '/vendor/'

          add_group 'Models', 'app/models'
          add_group 'Controllers', 'app/controllers'
          add_group 'Services', 'app/services'
          add_group 'Jobs', 'app/jobs'
          add_group 'Mailers', 'app/mailers'
          add_group 'Serializers', 'app/serializers'

          formatter SimpleCov::Formatter::MultiFormatter.new([
            SimpleCov::Formatter::HTMLFormatter,
            SimpleCov::Formatter::JSONFormatter
          ])

          minimum_coverage #{threshold}
          minimum_coverage_by_file 50
        end
      RUBY
    end
  end
end
