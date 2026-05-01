# frozen_string_literal: true

require "spec_helper"
require "test_report_kit/metrics_calculator"
require "json"

RSpec.describe TestReportKit::MetricsCalculator do
  let(:config) do
    TestReportKit.configure do |c|
      c.project_root = "/app"
      c.slow_test_threshold = 5.0
    end
    TestReportKit.configuration
  end

  let(:simplecov_data) do
    {
      "/app/app/services/cart_optimizer.rb" => {
        "lines" => [1, 1, nil, 1, 0, 0, nil, nil, nil, 1],
        "branches" => {}
      },
      "/app/app/models/order.rb" => {
        "lines" => [1, 1, 1, nil, 1, 0, 0, nil, 1, nil],
        "branches" => {}
      },
      "/app/app/models/product.rb" => {
        "lines" => [1, 1, 1, 1, nil, 1, 1, 1, 1, nil],
        "branches" => {}
      }
    }
  end

  let(:rspec_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "rspec_results.json"))) }
  let(:factory_prof_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "factory_prof.json"))) }
  let(:event_prof_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "event_prof.json"))) }
  let(:rspec_dissect_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "rspec_dissect.json"))) }
  let(:git_churn_data) { JSON.parse(File.read(File.join(FIXTURES_PATH, "git_churn.json"))) }
  let(:diff_coverage) { nil }

  let(:calculator) do
    described_class.new(
      simplecov_data: simplecov_data,
      rspec_data: rspec_data,
      factory_prof_data: factory_prof_data,
      event_prof_data: event_prof_data,
      rspec_dissect_data: rspec_dissect_data,
      git_churn_data: git_churn_data,
      diff_coverage: diff_coverage,
      config: config
    )
  end

  let(:result) { calculator.call }

  describe "overall_coverage" do
    it "computes total, covered, missed lines" do
      cov = result[:overall_coverage]
      expect(cov[:total_lines]).to be > 0
      expect(cov[:covered_lines]).to be > 0
      expect(cov[:missed_lines]).to be >= 0
      expect(cov[:total_lines]).to eq(cov[:covered_lines] + cov[:missed_lines])
    end

    it "computes coverage percentage" do
      cov = result[:overall_coverage]
      expect(cov[:coverage_pct]).to be_a(Float)
      expect(cov[:coverage_pct]).to be_between(0, 100)
    end

    it "returns nil when no simplecov data" do
      calc = described_class.new(
        simplecov_data: nil, rspec_data: nil, factory_prof_data: nil,
        event_prof_data: nil, rspec_dissect_data: nil, git_churn_data: nil,
        diff_coverage: nil, config: config
      )
      expect(calc.call[:overall_coverage]).to be_nil
    end

    describe "executed coverage (load-only vs test-exercised)" do
      # Three files. With node_count=1 ALL count==1 lines stay in `covered` (matches
      # SimpleCov default) but ONLY count>=2 lines count as `executed`. With
      # node_count=7, the threshold rises and the count==1 lines that were "executed"
      # in the smaller-N case fall back below.
      let(:simplecov_data) do
        {
          "/app/app/models/loaded_only.rb"  => { "lines" => [1, 1, 1, nil],   "branches" => {} },
          "/app/app/models/half_exercised.rb" => { "lines" => [1, 5, nil, 0], "branches" => {} },
          "/app/app/models/heavy.rb"          => { "lines" => [9, 12, nil, 8], "branches" => {} }
        }
      end

      # Fixture has 9 executable lines (12 entries, 3 nil), 8 with count > 0:
      #   loaded_only:    [1, 1, 1]     → 3 covered, 0 above 1, 0 above 7
      #   half_exercised: [1, 5,    0]  → 2 covered, 1 above 1 (the 5), 0 above 7
      #   heavy:          [9, 12,   8]  → 3 covered, 3 above 1, 3 above 7

      it "with node_count=1, counts every count>1 line as executed" do
        calc = described_class.new(
          simplecov_data: simplecov_data, rspec_data: rspec_data,
          factory_prof_data: factory_prof_data, event_prof_data: event_prof_data,
          rspec_dissect_data: rspec_dissect_data, git_churn_data: git_churn_data,
          diff_coverage: diff_coverage, config: config, node_count: 1
        )
        cov = calc.call[:overall_coverage]
        expect(cov[:total_lines]).to eq(9)
        expect(cov[:covered_lines]).to eq(8)
        expect(cov[:coverage_pct]).to eq(88.9)
        expect(cov[:executed_lines]).to eq(4) # 5, 9, 12, 8
        expect(cov[:executed_coverage_pct]).to eq(44.4)
        expect(cov[:node_count]).to eq(1)
      end

      it "with node_count=7, raises the threshold so count<=7 lines aren't executed" do
        calc = described_class.new(
          simplecov_data: simplecov_data, rspec_data: rspec_data,
          factory_prof_data: factory_prof_data, event_prof_data: event_prof_data,
          rspec_dissect_data: rspec_dissect_data, git_churn_data: git_churn_data,
          diff_coverage: diff_coverage, config: config, node_count: 7
        )
        cov = calc.call[:overall_coverage]
        # covered_lines unchanged (still uses count > 0)
        expect(cov[:covered_lines]).to eq(8)
        expect(cov[:coverage_pct]).to eq(88.9)
        # Lines with count > 7: heavy[9, 12, 8] only = 3
        expect(cov[:executed_lines]).to eq(3)
        expect(cov[:executed_coverage_pct]).to eq(33.3)
        expect(cov[:node_count]).to eq(7)
      end

      it "exposes per-file executed_coverage_pct in file_coverage_list" do
        calc = described_class.new(
          simplecov_data: simplecov_data, rspec_data: rspec_data,
          factory_prof_data: factory_prof_data, event_prof_data: event_prof_data,
          rspec_dissect_data: rspec_dissect_data, git_churn_data: git_churn_data,
          diff_coverage: diff_coverage, config: config, node_count: 7
        )
        files = calc.call[:file_coverage]
        loaded = files.find { |f| f[:path] == "app/models/loaded_only.rb" }
        heavy  = files.find { |f| f[:path] == "app/models/heavy.rb" }
        expect(loaded[:coverage_pct]).to eq(100.0)
        expect(loaded[:executed_coverage_pct]).to eq(0.0)  # all 3 lines have count=1, none > 7
        expect(heavy[:coverage_pct]).to eq(100.0)
        expect(heavy[:executed_coverage_pct]).to eq(100.0) # all 3 lines have count >= 8
      end
    end
  end

  describe "file_coverage" do
    it "returns per-file coverage with risk scores" do
      files = result[:file_coverage]
      expect(files).to be_an(Array)
      expect(files.first).to include(:path, :coverage_pct, :churn, :risk_score)
    end

    it "sorts by risk score descending" do
      files = result[:file_coverage]
      scores = files.map { |f| f[:risk_score] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it "computes risk as churn * (100 - coverage)" do
      files = result[:file_coverage]
      cart = files.find { |f| f[:path] == "app/services/cart_optimizer.rb" }
      expected_risk = (18 * (100 - cart[:coverage_pct])).round(0)
      expect(cart[:risk_score]).to eq(expected_risk)
    end
  end

  describe "rspec_summary" do
    it "returns duration and counts" do
      summary = result[:rspec_summary]
      expect(summary[:duration_seconds]).to eq(342.7)
      expect(summary[:duration_formatted]).to eq("5m 42s")
      expect(summary[:example_count]).to eq(4521)
      expect(summary[:failure_count]).to eq(0)
      expect(summary[:pending_count]).to eq(23)
    end
  end

  describe "slowest_tests" do
    it "returns tests sorted by duration descending" do
      tests = result[:slowest_tests]
      expect(tests.first[:duration]).to eq(12.41)
      expect(tests.first[:description]).to include("payment capture timeout")
    end

    it "marks tests above threshold as slow" do
      tests = result[:slowest_tests]
      expect(tests.first[:slow]).to be true
      fast = tests.find { |t| t[:duration] < 5.0 }
      expect(fast[:slow]).to be false if fast
    end

    it "excludes pending tests" do
      tests = result[:slowest_tests]
      statuses = tests.map { |t| t[:status] }
      expect(statuses).not_to include("pending")
    end
  end

  describe "factory_health" do
    it "returns factory stats with cascade ratios" do
      health = result[:factory_health]
      expect(health[:total_count]).to eq(15832)
      expect(health[:stats]).to be_an(Array)

      order = health[:stats].find { |s| s[:name] == "order" }
      expect(order[:cascade_ratio]).to eq(2.4) # 2847/1200

      order_item = health[:stats].find { |s| s[:name] == "order_item" }
      expect(order_item[:cascade_ratio]).to eq(7.4) # 891/120
    end

    it "generates optimization suggestions" do
      health = result[:factory_health]
      expect(health[:suggestions]).to be_an(Array)
      expect(health[:suggestions].any? { |s| s[:factory] == "order_item" }).to be true
    end
  end

  describe "insights" do
    it "identifies high-risk files" do
      high_risk = result[:insights][:high_risk]
      expect(high_risk).to be_an(Array)
      paths = high_risk.map { |f| f[:path] }
      expect(paths).to include("app/services/cart_optimizer.rb")
    end

    it "identifies false security files" do
      false_sec = result[:insights][:false_security]
      expect(false_sec).to be_an(Array)
      # CartOptimizerSpec has 60.88% before + 15.03% let = 75.91% > 70%
      descs = false_sec.map { |f| f[:description] }
      expect(descs).to include("CartOptimizerSpec")
    end

    it "identifies untested hot paths" do
      hot = result[:insights][:untested_hot_paths]
      expect(hot).to be_an(Array)
      # pricing_engine has 22 commits and no coverage data
      paths = hot.map { |f| f[:path] }
      expect(paths).to include("app/services/pricing_engine.rb")
    end
  end
end
