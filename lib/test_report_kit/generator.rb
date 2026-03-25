# frozen_string_literal: true

require "erb"
require "json"
require "fileutils"

module TestReportKit
  class Generator
    TEMPLATE_DIR = File.expand_path("templates", __dir__)

    def initialize(metrics:, diff_coverage:, data_loader:, config: TestReportKit.configuration)
      @metrics       = metrics
      @diff_coverage = diff_coverage
      @data_loader   = data_loader
      @config        = config
    end

    def generate
      html = render_template("dashboard")
      output_path = File.join(@config.output_dir, "index.html")
      FileUtils.mkdir_p(@config.output_dir)
      File.write(output_path, html)
      output_path
    end

    private

    def render_template(name)
      path = File.join(TEMPLATE_DIR, "#{name}.html.erb")
      template = File.read(path)
      ERB.new(template, trim_mode: "-").result(binding)
    end

    def render_partial(name)
      path = File.join(TEMPLATE_DIR, "_#{name}.html.erb")
      template = File.read(path)
      ERB.new(template, trim_mode: "-").result(binding)
    end

    # ── Data accessors for templates ──

    def project_name
      @config.resolved_project_name
    end

    def timestamp
      Time.now.strftime("%b %d, %Y · %H:%M %Z").downcase
    end

    def branch
      ENV.fetch("TEST_REPORT_BRANCH", `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip)
    end

    def sha
      ENV.fetch("TEST_REPORT_SHA", `git rev-parse --short HEAD 2>/dev/null`.strip)[0..6]
    end

    def overall_coverage
      @metrics[:overall_coverage]
    end

    def file_coverage
      @metrics[:file_coverage] || []
    end

    def rspec_summary
      @metrics[:rspec_summary]
    end

    def slowest_tests
      @metrics[:slowest_tests] || []
    end

    def factory_health
      @metrics[:factory_health]
    end

    def insights
      @metrics[:insights] || {}
    end

    def diff_cov
      @diff_coverage
    end

    def rspec_dissect_data
      @data_loader.rspec_dissect_data
    end

    def event_prof_data
      @data_loader.event_prof_data
    end

    # ── Formatting helpers ──

    def coverage_color(pct)
      return "var(--text-muted)" unless pct
      if pct >= 80 then "var(--green)"
      elsif pct >= 60 then "var(--yellow)"
      else "var(--red)"
      end
    end

    def risk_color(score)
      if score >= 500 then "var(--red)"
      elsif score >= 200 then "var(--yellow)"
      else "var(--green)"
      end
    end

    def risk_bg(score)
      if score >= 500 then "var(--red-dim)"
      elsif score >= 200 then "var(--yellow-dim)"
      else "var(--green-dim)"
      end
    end

    def severity_color(severity)
      case severity
      when "critical" then "var(--red)"
      when "high" then "var(--orange)"
      when "medium" then "var(--yellow)"
      else "var(--text-muted)"
      end
    end

    def format_number(n)
      return "—" unless n
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def h(text)
      ERB::Util.html_escape(text.to_s)
    end

    def highlight_ruby(code)
      code = h(code).dup
      code.gsub!(/\b(def|end|if|else|elsif|unless|do|class|module|raise|return|next|begin|rescue|ensure|yield|nil|true|false|self)\b/, '<span style="color: #c678dd;">\1</span>')
      code.gsub!(/(&quot;[^&]*?&quot;|&#39;[^&]*?&#39;)/, '<span style="color: #98c379;">\1</span>')
      code.gsub!(/(:[a-zA-Z_]\w*)/, '<span style="color: #98c379;">\1</span>')
      code.gsub!(/\b([A-Z][a-zA-Z0-9]*(?:::[A-Z][a-zA-Z0-9]*)*)\b/, '<span style="color: var(--cyan);">\1</span>')
      code.gsub!(/(#.*)$/, '<span style="color: var(--text-muted);">\1</span>')
      code
    end

    def json_data
      {
        diff_coverage: @diff_coverage&.to_h,
        file_coverage: file_coverage,
        factory_health: factory_health,
        insights: insights
      }.to_json
    end

    def all_passing?
      return true unless rspec_summary
      (rspec_summary[:failure_count] || 0) == 0
    end
  end
end
