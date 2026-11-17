# frozen_string_literal: true

module Woods
  class WorktreeSeed
    # Why a seed fell back, written for a terminal or a log: a path in the
    # worktree relative to its root, any other absolute path by its last
    # component, so the line names no host path.
    #
    # @api private
    class PortableReason
      ABSOLUTE_PATH = %r{(?<![\w.~-])/[^\s,;:()'"]+}

      # @param root [String, Pathname] the worktree's application root
      def initialize(root)
        expanded = File.expand_path(root.to_s)
        @roots = [expanded, real(expanded)].uniq
      end

      # @param reason [String]
      # @return [String]
      def call(reason)
        reason.gsub(ABSOLUTE_PATH) do |path|
          inside = @roots.find { |root| path.start_with?("#{root}/") }
          inside ? path.delete_prefix("#{inside}/") : File.basename(path)
        end
      end

      private

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end
    end
  end
end
