# frozen_string_literal: true

require 'json'

# Splitting and timing rules for script/parallel-rspec, kept free of process
# handling so they can be tested directly.
module ParallelRspec
  ROOT = File.expand_path('..', __dir__)
  TIMINGS_PATH = File.join(ROOT, 'script', 'parallel_rspec_timings.json')
  DEFAULT_SECONDS = 1.0

  module_function

  # @param paths [Array<String>] spec files or directories
  # @return [Array<String>] sorted spec files, relative to the repository root when inside it
  def spec_files(paths)
    paths = ['spec'] if paths.empty?
    files = paths.flat_map do |path|
      absolute = File.expand_path(path, ROOT)
      File.directory?(absolute) ? Dir[File.join(absolute, '**', '*_spec.rb')] : [absolute]
    end
    files.map { |file| file.delete_prefix("#{ROOT}/") }.uniq.sort
  end

  # Longest-processing-time-first greedy split.
  #
  # @param files [Array<String>]
  # @param timings [Hash{String=>Numeric}] seconds per file
  # @param count [Integer] number of groups
  # @return [Array<Array<String>>] non-empty groups of files
  def split(files, timings, count)
    groups = Array.new([count, files.size].min) { { files: [], seconds: 0.0 } }
    files.sort_by { |file| [-timings.fetch(file, DEFAULT_SECONDS), file] }.each do |file|
      group = groups.min_by { |candidate| candidate[:seconds] }
      group[:files] << file
      group[:seconds] += timings.fetch(file, DEFAULT_SECONDS)
    end
    groups.map { |group| group[:files].sort }
  end

  # @param report_path [String] output of rspec --format json
  # @return [Hash{String=>Float}] summed example seconds per spec file
  def timings_from(report_path)
    seconds = Hash.new(0.0)
    JSON.parse(File.read(report_path)).fetch('examples').each do |example|
      seconds[example.fetch('file_path').delete_prefix('./')] += example.fetch('run_time')
    end
    seconds.transform_values { |value| value.round(2) }.sort.to_h
  end
end
