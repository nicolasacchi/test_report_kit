# frozen_string_literal: true

require "fileutils"
require "json"

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

    def run_full
      validate_dependencies
      setup_simplecov
      rspec_exit = run_rspec(profiling: true, coverage: true)
      compute_git_churn
      generate_report
      rspec_exit
    end

    def run_coverage
      validate_dependencies(require_test_prof: false)
      setup_simplecov
      rspec_exit = run_rspec(profiling: false, coverage: true)
      compute_git_churn
      generate_report
      rspec_exit
    end

    def run_profile
      validate_dependencies(require_simplecov: false)
      rspec_exit = run_rspec(profiling: true, coverage: false)
      compute_git_churn
      generate_report
      rspec_exit
    end

    def run_generate
      generate_report
      0
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
        env["EVENT_PROF"] = "sql.active_record"
      end
      if profiling && @config.profilers.include?(:rspec_dissect)
        env["RD_PROF"] = "1"
      end

      rspec_json_path = File.join(@config.output_dir, "rspec_results.json")
      output_log = File.join(@config.output_dir, "test_output.log")

      cmd_parts = ["bundle", "exec", "rspec"]
      cmd_parts += ["--require", @simplecov_init_path] if coverage && @simplecov_init_path
      cmd_parts += ["--format", "json", "--out", rspec_json_path]
      cmd_parts += ["--format", "progress"]

      puts "TestReportKit: Running RSpec..."
      pid = spawn(env, *cmd_parts, out: output_log, err: [:child, :out])
      Process.wait(pid)
      rspec_exit = $?.exitstatus

      # Split captured output for text-based profilers
      split_profiler_output(output_log) if profiling

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
      require_relative "data_loader"
      require_relative "diff_coverage"
      require_relative "metrics_calculator"
      require_relative "generator"
      require_relative "summary_exporter"

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

      puts "TestReportKit: Dashboard → #{report_path}"
      puts "TestReportKit: Summary  → #{summary_path}"
    end

    # ── Helpers ──

    def split_profiler_output(log_path)
      return unless File.exist?(log_path)

      content = File.read(log_path)

      # Extract EventProf section
      if (match = content.match(/EventProf results for .+?(?=\n\n[A-Z]|\n\nFinished|\z)/m))
        File.write(File.join(@config.output_dir, "event_prof_output.txt"), match[0])
      end

      # Extract RSpecDissect section
      if (match = content.match(/RSpecDissect report.+?(?=\n\n[A-Z]|\n\nFinished|\z)/m))
        File.write(File.join(@config.output_dir, "rspec_dissect_output.txt"), match[0])
      end
    end

    def simplecov_init_content
      threshold = @config.coverage_threshold
      <<~RUBY
        # Auto-generated by TestReportKit — do not edit
        require 'simplecov'
        require 'simplecov-json'

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
