# frozen_string_literal: true

require 'digest'
require 'pathname'
require_relative 'response'

module WoodsDevelopment
  module TypeSafe
    # Bounded byte fingerprints, with explicit relative names and no source evaluation.
    class ReceiptInventory
      MAX_FILES = 20_000
      MAX_FILE_BYTES = 67_108_864
      MAX_TOTAL_BYTES = 536_870_912
      MAX_DEPTH = 64

      def self.check(condition, message)
        raise InvalidEvidence, message unless condition
      end

      def self.validate_path(path)
        check(path.is_a?(String) && path.encoding.ascii_compatible?, 'Invalid receipt path')
        check(path.dup.force_encoding(Encoding::UTF_8).valid_encoding?, 'Invalid receipt path encoding')
        check(!path.empty? && !path.match?(%r{\A(?:/|[A-Za-z]:)|[\x00\\]}), 'Invalid receipt path')
        check(path.split('/', -1).none? { |part| part.empty? || part == '.' || part == '..' }, 'Invalid receipt path')
      end

      def initialize(root)
        @root = File.realpath(root)
        self.class.check(File.directory?(@root), 'Receipt root must be a directory')
      end

      def fingerprint(paths)
        self.class.check(paths.is_a?(Array) && paths.length.between?(1, MAX_FILES), 'Invalid receipt inventory size')
        paths.each { |path| self.class.validate_path(path) }
        self.class.check(paths.uniq.length == paths.length, 'Duplicate receipt paths')
        total = 0
        paths.sort.map do |path|
          bytes = read(path, [MAX_FILE_BYTES, MAX_TOTAL_BYTES - total].min)
          total += bytes.bytesize
          { 'path' => path.dup, 'sha256' => Digest::SHA256.hexdigest(bytes), 'bytes' => bytes.bytesize }
        end
      end

      def read(path, limit = MAX_FILE_BYTES)
        self.class.validate_path(path)
        resolved = File.realpath(File.join(@root, path))
        self.class.check(resolved.start_with?(File.join(@root, '')), 'Receipt file escapes its root')
        self.class.check(File.stat(resolved).file?, 'Receipt input must be a regular file')
        File.open(resolved, 'rb') { |file| read_regular(file, limit) }
      end

      def artifacts
        paths = []
        queue = [['', 0]]
        @visited = 0
        until queue.empty?
          directory, depth = queue.shift
          self.class.check(depth <= MAX_DEPTH, 'Receipt traversal limit exceeded')
          Dir.each_child(File.join(@root, directory)) do |child|
            relative = directory.empty? ? child : File.join(directory, child)
            collect_artifact(relative, depth, queue, paths)
          end
        end
        self.class.check(%w[manifest.json dependency_graph.json].all? { |path| paths.include?(path) },
                         'Receipt requires manifest and graph artifacts')
        fingerprint(paths)
      end

      private

      def read_regular(file, limit)
        stat = file.stat
        self.class.check(stat.file?, 'Receipt input must be a regular file')
        self.class.check(stat.size <= limit, 'Receipt byte limit exceeded')
        # IO#read can allocate the requested capacity even for a tiny regular file.
        # One extra byte detects growth without allocating the full configured ceiling.
        bytes = file.read(stat.size + 1) || ''.b
        self.class.check(bytes.bytesize == stat.size, 'Receipt file size changed while reading')
        bytes
      end

      def collect_artifact(path, depth, queue, paths)
        @visited += 1
        self.class.check(@visited <= MAX_FILES * 2, 'Receipt traversal limit exceeded')
        self.class.validate_path(path)
        stat = File.lstat(File.join(@root, path))
        self.class.check(!stat.symlink? && (stat.file? || stat.directory?), 'Unsafe receipt artifact')
        if stat.directory?
          queue << [path, depth + 1]
        elsif path.end_with?('.json')
          paths << path
        end
      end
    end
  end
end
