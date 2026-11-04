# frozen_string_literal: true

require 'open3'
require_relative '../git_command'

module Woods
  module SelfMap
    # Classifies the Git input universe without pretending all files are parsed.
    class Inventory
      def initialize(root, snapshot)
        @root = root.to_s
        @snapshot = snapshot
      end

      def to_h
        covered = Array(@snapshot.health['files']).to_h { |file| [file.fetch('path'), file] }
        paths, scope = paths_and_scope
        { 'scope' => scope, 'files' => (paths | covered.keys).sort.map do |path|
          covered[path] || { 'path' => path, 'mode' => File.file?(File.join(@root, path)) ? 'not_mapped' : 'absent' }
        end }
      end

      private

      def paths_and_scope
        output, _error, status = Open3.capture3(*GitCommand.argv(@root, 'ls-files', '-z', '--cached', '--others',
                                                                 '--exclude-standard'))
        status.success? ? [output.split("\0"), 'git_nonignored'] : [[], 'covered_sources_only_git_unavailable']
      rescue Errno::ENOENT
        [[], 'covered_sources_only_git_unavailable']
      end
    end
  end
end
