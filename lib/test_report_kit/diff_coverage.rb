# frozen_string_literal: true

module TestReportKit
  class DiffCoverage
    HUNK_HEADER_RE = /^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@/
    DIFF_FILE_RE   = /^diff --git a\/.+ b\/(.+)$/
    RUBY_APP_RE    = /\A(?:app|lib)\/.+\.rb\z/

    Result = Struct.new(
      :base_branch, :base_sha, :head_sha,
      :total_changed_lines, :executable_changed_lines,
      :covered_changed_lines, :uncovered_changed_lines,
      :diff_coverage_pct, :threshold, :passed, :files,
      keyword_init: true
    )

    FileCoverage = Struct.new(
      :path, :changed_lines, :covered_lines, :uncovered_lines,
      :non_executable_lines, :diff_coverage_pct, :not_loaded,
      :uncovered_content,
      keyword_init: true
    )

    def initialize(coverage_data:, config: TestReportKit.configuration)
      @coverage_data = coverage_data
      @config = config
    end

    def call
      diff_text = run_git_diff
      return nil if diff_text.nil? || diff_text.strip.empty?

      changed_files = parse_git_diff(diff_text)
      return nil if changed_files.empty?

      file_results = changed_files.map { |path, lines| analyze_file(path, lines) }

      total_changed     = file_results.sum { |f| f.changed_lines.size }
      total_executable  = file_results.sum { |f| f.covered_lines.size + f.uncovered_lines.size }
      total_covered     = file_results.sum { |f| f.covered_lines.size }
      total_uncovered   = file_results.sum { |f| f.uncovered_lines.size }
      pct = total_executable > 0 ? (total_covered.to_f / total_executable * 100).round(1) : nil

      Result.new(
        base_branch: @config.diff_base_branch,
        base_sha: git_merge_base,
        head_sha: git_head_sha,
        total_changed_lines: total_changed,
        executable_changed_lines: total_executable,
        covered_changed_lines: total_covered,
        uncovered_changed_lines: total_uncovered,
        diff_coverage_pct: pct,
        threshold: @config.diff_coverage_threshold,
        passed: pct.nil? ? nil : pct >= @config.diff_coverage_threshold,
        files: file_results.sort_by { |f| f.diff_coverage_pct || -1 }
      )
    end

    def parse_git_diff(diff_text)
      files = {}
      current_file = nil

      diff_text.each_line do |line|
        if (match = line.match(DIFF_FILE_RE))
          candidate = match[1]
          current_file = RUBY_APP_RE.match?(candidate) ? candidate : nil
        elsif current_file && (match = line.match(HUNK_HEADER_RE))
          start_line = match[1].to_i
          count = (match[2] || "1").to_i
          next if count == 0 # pure deletion

          files[current_file] ||= []
          (start_line...(start_line + count)).each { |n| files[current_file] << n }
        end
      end

      files.each_value(&:uniq!)
      files
    end

    private

    def analyze_file(relative_path, changed_lines)
      absolute_path = File.join(@config.project_root, relative_path)
      file_coverage = find_coverage(absolute_path)

      covered = []
      uncovered = []
      non_executable = []
      not_loaded = file_coverage.nil?

      changed_lines.each do |line_num|
        if not_loaded
          uncovered << line_num
        else
          line_cov = file_coverage[line_num - 1] # 0-indexed array
          if line_cov.nil?
            non_executable << line_num
          elsif line_cov > 0
            covered << line_num
          else
            uncovered << line_num
          end
        end
      end

      executable = covered.size + uncovered.size
      pct = executable > 0 ? (covered.size.to_f / executable * 100).round(1) : nil

      FileCoverage.new(
        path: relative_path,
        changed_lines: changed_lines,
        covered_lines: covered,
        uncovered_lines: uncovered,
        non_executable_lines: non_executable,
        diff_coverage_pct: pct,
        not_loaded: not_loaded,
        uncovered_content: not_loaded ? [] : build_uncovered_content(relative_path, uncovered)
      )
    end

    def build_uncovered_content(relative_path, uncovered)
      return [] if uncovered.empty?

      source_path = File.join(@config.project_root, relative_path)
      return [] unless File.exist?(source_path)

      source_lines = File.readlines(source_path, chomp: true)
      content = []

      group_consecutive_lines(uncovered).each_with_index do |group, idx|
        content << { type: :gap } if idx > 0

        # 1 context line before
        ctx_before = group.first - 1
        if ctx_before >= 1 && ctx_before <= source_lines.size && !uncovered.include?(ctx_before)
          content << { type: :context, line: ctx_before, content: source_lines[ctx_before - 1] }
        end

        # Uncovered lines
        group.each do |line_num|
          next if line_num < 1 || line_num > source_lines.size
          content << { type: :uncovered, line: line_num, content: source_lines[line_num - 1] }
        end

        # 1 context line after
        ctx_after = group.last + 1
        if ctx_after >= 1 && ctx_after <= source_lines.size && !uncovered.include?(ctx_after)
          content << { type: :context, line: ctx_after, content: source_lines[ctx_after - 1] }
        end
      end

      content
    end

    def group_consecutive_lines(lines)
      return [] if lines.empty?
      sorted = lines.sort
      groups = [[sorted.first]]
      sorted[1..].each do |line|
        if line == groups.last.last + 1
          groups.last << line
        else
          groups << [line]
        end
      end
      groups
    end

    def find_coverage(absolute_path)
      return nil unless @coverage_data

      # Try exact match first, then try matching by relative suffix
      if @coverage_data.key?(absolute_path)
        data = @coverage_data[absolute_path]
        return data.is_a?(Hash) ? data["lines"] : data
      end

      # Fallback: match by filename suffix (handles different project roots)
      @coverage_data.each do |path, data|
        if path.end_with?(absolute_path.sub(@config.project_root, ""))
          return data.is_a?(Hash) ? data["lines"] : data
        end
      end

      nil
    end

    def run_git_diff
      base = resolve_base_ref
      return nil unless base

      cmd = "git diff #{base}...HEAD --unified=0 --no-color --diff-filter=ACMR --find-renames"
      result = `#{cmd} 2>/dev/null`
      $?.success? ? result : nil
    end

    def resolve_base_ref
      base = @config.diff_base_branch
      ["git rev-parse --verify #{base} 2>/dev/null", "git rev-parse --verify origin/#{base} 2>/dev/null"].each do |cmd|
        result = `#{cmd}`.strip
        return result[0..11] if $?.success? && !result.empty?
      end
      nil
    rescue Errno::ENOENT
      nil
    end

    def git_merge_base
      base = resolve_base_ref
      return "" unless base
      `git merge-base #{base} HEAD 2>/dev/null`.strip[0..6]
    end

    def git_head_sha
      `git rev-parse --short HEAD 2>/dev/null`.strip
    end
  end
end
