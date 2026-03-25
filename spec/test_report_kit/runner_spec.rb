# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/runner"
require "tmpdir"
require "fileutils"

RSpec.describe TestReportKit::Runner do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = tmpdir
      c.output_dir = File.join(tmpdir, "tmp/test_report")
    end
    TestReportKit.configuration
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#run! with :generate mode" do
    let(:runner) { described_class.new(config, mode: :generate) }

    before do
      # Set up fixture data in the expected locations
      output_dir = config.output_dir
      FileUtils.mkdir_p(output_dir)
      FileUtils.mkdir_p(File.join(tmpdir, "coverage"))

      FileUtils.cp(File.join(FIXTURES_PATH, "simplecov_resultset.json"),
                    File.join(tmpdir, "coverage/.resultset.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "rspec_results.json"),
                    File.join(output_dir, "rspec_results.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "factory_prof.json"),
                    File.join(output_dir, "factory_prof.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "event_prof.json"),
                    File.join(output_dir, "event_prof.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "rspec_dissect.json"),
                    File.join(output_dir, "rspec_dissect.json"))
      FileUtils.cp(File.join(FIXTURES_PATH, "git_churn.json"),
                    File.join(output_dir, "git_churn.json"))
    end

    it "generates report from existing files" do
      exit_code = runner.run!
      expect(exit_code).to eq(0)
      expect(File.exist?(File.join(config.output_dir, "index.html"))).to be true
      expect(File.exist?(File.join(config.output_dir, "summary.json"))).to be true
    end

    it "produces valid HTML" do
      runner.run!
      html = File.read(File.join(config.output_dir, "index.html"))
      expect(html).to include("<!DOCTYPE html>")
      expect(html).to include("Diff Coverage")
      expect(html).to include("Coverage")
    end

    it "produces valid summary JSON" do
      runner.run!
      summary = JSON.parse(File.read(File.join(config.output_dir, "summary.json")))
      expect(summary).to have_key("coverage_pct")
      expect(summary).to have_key("diff_coverage_pct")
      expect(summary).to have_key("generated_at")
    end
  end

  describe "#run! with unknown mode" do
    it "raises an error" do
      runner = described_class.new(config, mode: :unknown)
      expect { runner.run! }.to raise_error(TestReportKit::Error, /Unknown mode/)
    end
  end

  describe "split_profiler_output" do
    let(:runner) { described_class.new(config, mode: :generate) }

    it "extracts EventProf section from log" do
      log_path = File.join(tmpdir, "test_output.log")
      FileUtils.mkdir_p(config.output_dir)
      File.write(log_path, <<~LOG)
        Running tests...
        ..........

        EventProf results for sql.active_record

        Total time: 00:15.234 of 01:30.000 (16.93%)
        Total events: 4567

        Finished in 90 seconds
      LOG

      runner.send(:split_profiler_output, log_path)
      output = File.join(config.output_dir, "event_prof_output.txt")
      expect(File.exist?(output)).to be true
      expect(File.read(output)).to include("EventProf results")
    end
  end
end
