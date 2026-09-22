# frozen_string_literal: true

require 'json'
require 'fileutils'

class FixtureSnapshots
  def initialize(dir:, retention:)
    @dir = dir
    @retention = retention
    FileUtils.mkdir_p(@dir)
  end

  def capture(sha, timestamp)
    raise ArgumentError, 'invalid SHA' unless sha.match?(/\A[0-9a-f]+\z/i)

    File.write(snapshot_path(sha), JSON.generate(git_sha: sha, extracted_at: timestamp))
    prune_snapshots(protect: sha)
  end

  private

  def snapshot_path(sha)
    File.join(@dir, "#{sha}.json")
  end

  def snapshot_files
    Dir.glob(File.join(@dir, '*.json')).select do |path|
      File.basename(path, '.json').match?(/\A[0-9a-f]+\z/i) && File.file?(path)
    end
  end

  def read_snapshot(path)
    data = JSON.parse(File.read(path))
    data if data.is_a?(Hash)
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def prune_snapshots(protect:)
    summaries = retention_summaries
    overflow = summaries.size - @retention
    return unless overflow.positive?

    summaries.reject { |summary| summary[:git_sha] == protect }
             .sort_by { |summary| [summary[:extracted_at], summary[:git_sha]] }
             .first(overflow)
             .each { |summary| FileUtils.rm_f(snapshot_path(summary[:git_sha])) }
  end

  def retention_summaries
    snapshot_files.map do |path|
      sha = File.basename(path, '.json')
      data = read_snapshot(path) || {}
      { git_sha: sha, extracted_at: data.fetch('extracted_at', '') }
    end
  end
end
