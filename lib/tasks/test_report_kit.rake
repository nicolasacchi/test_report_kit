# frozen_string_literal: true

require "test_report_kit"

namespace :test_report do
  desc "Run full test suite with coverage, profiling, and diff coverage — generate HTML dashboard"
  task full: :environment do
    TestReportKit.run!(mode: :full)
  end

  desc "Run tests with coverage only (no profiling) — faster"
  task coverage: :environment do
    TestReportKit.run!(mode: :coverage)
  end

  desc "Run tests with profiling only (no coverage)"
  task profile: :environment do
    TestReportKit.run!(mode: :profile)
  end

  desc "Re-generate HTML dashboard from existing JSON files (no test run)"
  task generate: :environment do
    TestReportKit.run!(mode: :generate)
  end
end
