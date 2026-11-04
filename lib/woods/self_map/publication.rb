# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative '../atomic_file'
require_relative '../coordination/pipeline_lock'

module Woods
  module SelfMap
    # Publishes complete immutable views; a failed run never advances the pointer.
    class Publication
      RETENTION = 3

      def initialize(output_dir)
        @output = Pathname.new(output_dir).expand_path
      end

      def publish(kind, files, &verify)
        key = Digest::SHA256.hexdigest(files.sort.map { |name, body| "#{name}\0#{body}" }.join("\0"))
        family = kind == 'guide' ? 'views' : 'reports'
        relative = File.join(family, key)
        Coordination::PipelineLock.new(lock_dir: @output.to_s, name: 'self_context').with_lock do
          directory = @output.join(relative)
          build(directory, files) unless directory.directory? && valid?(directory, files)
          verify.call
          pointer = kind == 'guide' ? 'current.json' : 'latest-impact.json'
          AtomicFile.write(@output.join(pointer), JSON.pretty_generate(schema_version: 1, path: relative))
          prune(family, directory)
          directory.to_s
        end
      end

      private

      def valid?(directory, files)
        files.all? { |name, body| directory.join(name).file? && AtomicFile.read(directory.join(name)) == body }
      end

      def build(directory, files)
        FileUtils.mkdir_p(directory.dirname)
        staging = Dir.mktmpdir('.staging-', directory.dirname.to_s)
        files.each { |name, body| AtomicFile.write(File.join(staging, name), body) }
        AtomicFile.sync_directory_tree(staging)
        raise IOError, 'Existing context view is corrupt; remove it and rerun' if directory.exist?

        File.rename(staging, directory)
        AtomicFile.fsync_directory(directory.dirname)
      ensure
        FileUtils.rm_rf(staging) if staging && File.directory?(staging)
      end

      def prune(family, current)
        directories = @output.join(family).children.select do |path|
          path.directory? && path.basename.to_s.match?(/\A[0-9a-f]{64}\z/)
        end
        others = directories.reject { |path| path == current }.sort_by { |path| -path.mtime.to_f }
        others.drop(RETENTION - 1).each { |path| FileUtils.rm_rf(path) }
      end
    end
  end
end
