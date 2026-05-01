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
      # Test fixture covering all four buckets: count==0 (uncovered), count==N
      # (load-only), count between 1 and N-1 (called in some shards), count > N
      # (called many times).
      let(:simplecov_data) do
        {
          "/app/app/models/loaded_only.rb"    => { "lines" => [1, 1, 1, nil],     "branches" => {} },
          "/app/app/models/half_exercised.rb" => { "lines" => [1, 5, nil, 0],     "branches" => {} },
          "/app/app/models/heavy.rb"          => { "lines" => [9, 12, nil, 8],    "branches" => {} }
        }
      end

      # 9 executable (12 entries minus 3 nils), 8 covered (1 zero):
      #   loaded_only:    [1, 1, 1]      → all count==1
      #   half_exercised: [1, 5, 0]      → one count==1, one count==5, one count==0
      #   heavy:          [9, 12, 8]     → all count > 7

      it "with node_count=1, count==1 lines are load-only and exclusion shifts to numerator + denominator" do
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
        # Load-only (count == 1): loaded_only[1,1,1] + half_exercised first [1] = 4
        expect(cov[:load_only_lines]).to eq(4)
        expect(cov[:testable_lines]).to eq(5) # 9 total − 4 load-only
        # Executed (count > 0 AND count != 1): half_exercised[5] + heavy[9,12,8] = 4
        expect(cov[:executed_lines]).to eq(4)
        # Of testable lines, 4 of 5 exercised
        expect(cov[:executed_coverage_pct]).to eq(80.0)
        expect(cov[:node_count]).to eq(1)
      end

      it "with node_count=7, count==7 lines are load-only and the smaller-count lines join executed" do
        # Bump heavy.rb to also include a count==7 line (load-only bucket at N=7).
        simplecov = {
          "/app/app/models/loaded_only.rb"    => { "lines" => [7, 7, 7, nil],    "branches" => {} },
          "/app/app/models/half_exercised.rb" => { "lines" => [7, 5, nil, 0],    "branches" => {} },
          "/app/app/models/heavy.rb"          => { "lines" => [9, 12, nil, 8],   "branches" => {} }
        }
        calc = described_class.new(
          simplecov_data: simplecov, rspec_data: rspec_data,
          factory_prof_data: factory_prof_data, event_prof_data: event_prof_data,
          rspec_dissect_data: rspec_dissect_data, git_churn_data: git_churn_data,
          diff_coverage: diff_coverage, config: config, node_count: 7
        )
        cov = calc.call[:overall_coverage]
        expect(cov[:covered_lines]).to eq(8)
        expect(cov[:coverage_pct]).to eq(88.9)
        # Load-only (count == 7): loaded_only[7,7,7] + half_exercised first [7] = 4
        expect(cov[:load_only_lines]).to eq(4)
        expect(cov[:testable_lines]).to eq(5)
        # Executed (count > 0 AND count != 7): half_exercised[5] + heavy[9,12,8] = 4
        expect(cov[:executed_lines]).to eq(4)
        expect(cov[:executed_coverage_pct]).to eq(80.0)
        expect(cov[:node_count]).to eq(7)
      end

      it "exposes per-file metrics with the testable denominator" do
        calc = described_class.new(
          simplecov_data: simplecov_data, rspec_data: rspec_data,
          factory_prof_data: factory_prof_data, event_prof_data: event_prof_data,
          rspec_dissect_data: rspec_dissect_data, git_churn_data: git_churn_data,
          diff_coverage: diff_coverage, config: config, node_count: 1
        )
        files = calc.call[:file_coverage]
        loaded = files.find { |f| f[:path] == "app/models/loaded_only.rb" }
        heavy  = files.find { |f| f[:path] == "app/models/heavy.rb" }

        # loaded_only.rb: 3 lines all count==1 → 100% covered, 0 testable, 0% executed
        expect(loaded[:coverage_pct]).to eq(100.0)
        expect(loaded[:load_only_lines]).to eq(3)
        expect(loaded[:testable_lines]).to eq(0)
        expect(loaded[:executed_coverage_pct]).to eq(0.0)

        # heavy.rb: 3 lines all count > 1 → 100% covered, 3 testable, 100% executed
        expect(heavy[:coverage_pct]).to eq(100.0)
        expect(heavy[:load_only_lines]).to eq(0)
        expect(heavy[:testable_lines]).to eq(3)
        expect(heavy[:executed_coverage_pct]).to eq(100.0)
      end

      it "uses per-file load thresholds when file_load_counts is provided" do
        # heavy.rb is in 3 shards (load count 3); loaded_only.rb is in 7 shards (load
        # count 7). With global node_count=7 alone, heavy.rb's [9, 12, 8] would be
        # mis-classified — but those values exceed both thresholds so they stay
        # `executed`. The discriminating case: a class-body line in heavy.rb at
        # count==3 should be load-only (matches its file's threshold), NOT executed.
        simplecov = {
          "/app/app/models/loaded_only.rb" => { "lines" => [7, 7, 7, nil],   "branches" => {} },
          "/app/app/models/heavy.rb"       => { "lines" => [3, 12, nil, 8], "branches" => {} }
        }
        calc = described_class.new(
          simplecov_data: simplecov, rspec_data: rspec_data,
          factory_prof_data: factory_prof_data, event_prof_data: event_prof_data,
          rspec_dissect_data: rspec_dissect_data, git_churn_data: git_churn_data,
          diff_coverage: diff_coverage, config: config,
          node_count: 7,
          file_load_counts: {
            "/app/app/models/loaded_only.rb" => 7,
            "/app/app/models/heavy.rb"       => 3
          }
        )
        cov = calc.call[:overall_coverage]
        # loaded_only: 3 × count==7 (its threshold) → 3 load_only
        # heavy:       count==3 (its threshold) is load_only; 12 and 8 are executed
        expect(cov[:load_only_lines]).to eq(4) # 3 + 1
        expect(cov[:executed_lines]).to eq(2)  # 12, 8
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
