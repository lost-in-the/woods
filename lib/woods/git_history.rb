# frozen_string_literal: true

require 'open3'
require 'time'
require_relative 'git_command'

module Woods
  # Stream HEAD-reachable touched-path events without pathspec simplification.
  # Raw NUL records keep filenames separate from commit fields; only requested
  # paths are retained. Merge diffs compare against the first parent, while
  # traversal still visits every parent. Requires Git 2.31 or newer.
  class GitHistory
    class ReadError < StandardError; end

    FORMAT = '%x00%H%x00%an%x00%cI%x00%s%x00'
    private_constant :FORMAT

    def initialize(root:, logger:)
      @root = root
      @logger = logger
    end

    # @return [Hash, nil] raw per-path aggregates, or nil on any incomplete read
    def read(paths, recent_after:)
      requested = paths.to_h { |path| [repository_prefix + path.b, path] }
      result = paths.to_h { |path| [path, {}] }
      stream { |stdout| parse(stdout, requested, result, recent_after) }
      result
    rescue StandardError => e
      @logger.warn('[Woods] Git enrichment omitted: history could not be read completely. ' \
                   'Git 2.31 or newer is required; check the application repository and git installation. ' \
                   "(#{e.class})")
      nil
    end

    private

    def repository_prefix
      return @repository_prefix if defined?(@repository_prefix)

      prefix, _error, status = Open3.capture3(*GitCommand.argv(@root, 'rev-parse', '--show-prefix'))
      raise ReadError, 'cannot resolve application path in repository' unless status.success?

      @repository_prefix = prefix.delete_suffix("\n").b
    end

    def stream
      argv = GitCommand.argv(@root, '-c', 'log.showSignature=false', 'log', 'HEAD',
                             '--since=365 days ago', '--root', '--raw', '-z', '--no-renames',
                             '--no-relative', '--no-ext-diff', '--encoding=UTF-8',
                             '--diff-merges=first-parent', "--format=#{FORMAT}")
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
        stdin.close
        stdout.binmode
        # Drain stderr without retaining a potentially unbounded diagnostic.
        drain = Thread.new { stderr.read(16_384) until stderr.eof? }
        begin
          yield stdout
          raise ReadError, "history command exited #{wait.value.exitstatus}" unless wait.value.success?
        ensure
          stdout.close
          drain.join
        end
      end
    end

    def token(io)
      value = io.gets("\0")
      return nil unless value
      raise ReadError, 'unterminated history record' unless value.end_with?("\0")

      value.delete_suffix("\0")
    end

    def parse(io, requested, result, recent_after)
      commit = nil
      while (field = token(io))
        next if field.empty?

        if field.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
          commit = read_commit(io, field, recent_after)
        elsif field.match?(/\A\n?:[0-7]{6} [0-7]{6} [0-9a-f]+ [0-9a-f]+ [A-Z]\z/)
          record_path(io, requested, result, commit)
        else
          raise ReadError, 'unexpected history record'
        end
      end
    end

    def read_commit(io, sha, recent_after)
      author, date, message = Array.new(3) { token(io) }
      raise ReadError, 'incomplete commit header' unless author && date && message

      { sha: sha, author: author.force_encoding(Encoding::UTF_8),
        date: date, message: message.force_encoding(Encoding::UTF_8), recent: Time.iso8601(date) > recent_after }
    end

    def record_path(io, requested, result, commit)
      path = token(io)
      raise ReadError, 'incomplete path record' unless commit && path

      relative = requested[path]
      record(result[relative], commit) if relative
    end

    def record(data, commit)
      data[:last_modified] ||= commit[:date]
      data[:last_author] ||= commit[:author]
      data[:commit_count] = data.fetch(:commit_count, 0) + 1
      data[:recent_count] = data.fetch(:recent_count, 0) + (commit[:recent] ? 1 : 0)
      commits = (data[:commits] ||= [])
      commits << commit if commits.size < 5
      (data[:contributors] ||= Hash.new(0))[commit[:author]] += 1
    end
  end
end
