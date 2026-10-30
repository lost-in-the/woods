# frozen_string_literal: true

require_relative 'git_ignore_inputs'

module Woods
  # {GitSourceFilter#skip_reasons} answers kept for the process, one path set
  # per root, for as long as Git's inputs ({GitIgnoreInputs}) keep their
  # fingerprint. Each incremental cycle builds a new skipped-files report;
  # over an unchanged tree it is answered from here with no git process (#721).
  module GitSourceAnswers
    # Answers for one path set, valid while the inputs keep their fingerprint.
    Kept = Struct.new(:inputs, :fingerprint, :reasons)

    @kept = {}
    @mutex = Mutex.new

    class << self
      # The answers kept for +relatives+ under +root+ while Git's inputs keep
      # their fingerprint; otherwise the block's, kept when it reports that
      # every git call answered. Paths that are not {.plain?} are never kept.
      #
      # @param root [String] application root
      # @param relatives [Array<String>] sorted, unique root-relative paths
      # @yieldreturn [Array(Hash, Boolean)] fresh answers, and whether they are complete
      # @return [Hash] the answers
      def answers(root, relatives)
        kept = @mutex.synchronize { @kept[root] }
        inputs, fingerprint = fingerprint(root, kept, relatives)
        return kept.reasons if fingerprint && kept&.fingerprint == fingerprint

        reasons, complete = yield
        @mutex.synchronize { @kept[root] = Kept.new(inputs, fingerprint, reasons) } if fingerprint && complete
        reasons
      end

      # Root-relative with no empty, `.` or `..` segment: Git echoes it as given.
      #
      # @param relative [String] a path as the caller spells it
      # @return [Boolean]
      def plain?(relative)
        !relative.start_with?('/') && relative.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
      end

      # Forget every kept answer (specs).
      # @return [void]
      def forget!
        @mutex.synchronize { @kept.clear }
      end

      private

      # Taken before any git call that answers, so a change made while Git
      # reads leaves a fingerprint the next call no longer matches.
      def fingerprint(root, kept, relatives)
        inputs = kept&.inputs || GitIgnoreInputs.resolve(root)
        return [inputs, nil] unless inputs && relatives.all? { |relative| plain?(relative) }

        [inputs, inputs.fingerprint(relatives)]
      end
    end
  end
end
