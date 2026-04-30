# frozen_string_literal: true

module TestReportKit
  class Configuration
    attr_accessor :project_name,
                  :output_dir,
                  :profilers,
                  :churn_days,
                  :coverage_threshold,
                  :diff_coverage_threshold,
                  :diff_base_branch,
                  :slow_test_threshold,
                  :factory_cascade_threshold,
                  :project_root,
                  :github_url,
                  :event_prof_event,
                  :fail_on_coverage,
                  :fail_on_diff_coverage,
                  :simplecov_track_files

    def initialize
      @project_name             = nil
      @output_dir               = "tmp/test_report"
      @profilers                = %i[factory_prof rspec_dissect event_prof]
      @churn_days               = 90
      @coverage_threshold       = 80
      @diff_coverage_threshold  = 90
      @diff_base_branch         = "main"
      @slow_test_threshold      = 5.0
      @factory_cascade_threshold = 10
      @project_root             = Dir.pwd
      @github_url               = nil
      @event_prof_event         = "factory.create"
      @fail_on_coverage         = false
      @fail_on_diff_coverage    = false
      # Glob passed to SimpleCov.track_files in the auto-generated init. With this set,
      # SimpleCov pre-registers every matching project file at finalization, so the
      # denominator stays stable across single-process and sharded runs (lazy-loading
      # no longer changes which files are "seen"). Set to nil to opt out and match a
      # Codecov-style number that only counts files actually autoloaded.
      @simplecov_track_files    = "{app,lib}/**/*.rb"
    end

    def resolved_project_name
      @project_name || File.basename(project_root)
    end
  end
end
