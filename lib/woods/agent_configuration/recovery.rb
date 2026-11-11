# frozen_string_literal: true

module Woods
  module AgentConfiguration
    # Validate every journal snapshot before restoring any managed file. A
    # journal marked committed holds a fully applied change and is only removed.
    module Recovery
      private

      def recover_journal(journal)
        plan = Plan.allocate
        plan.instance_variable_set(:@data, journal.fetch('plan'))
        plan.validate!(@layout)
        changes = plan.data.fetch('changes')
        originals = journal.fetch('originals')
        validate_originals!(originals, changes)
        changes.each { |change| validate_recovery_snapshot!(change) }
        originals.zip(changes).reverse_each { |original, change| restore_original(original, change) }
        File.unlink(journal_path)
      rescue KeyError, TypeError, ArgumentError => e
        raise Conflict, "Invalid recovery journal; retained for manual recovery: #{e.message}"
      end

      # A committed journal records a change that was fully applied; only its
      # removal was left undone, so it is removed and nothing is restored.
      #
      # @return [Boolean] true when the journal was committed and is now gone
      def discard_committed?(journal)
        return false unless journal['committed'] == true

        File.unlink(journal_path)
        true
      end

      # Keeps the journal's shape (plan and original paths) so readers that
      # validate it still can, but drops the original bytes: a committed
      # journal is never restored, and an older reader refuses it instead of
      # rolling back.
      def committed_journal(journal)
        journal.merge('committed' => true,
                      'originals' => journal.fetch('originals').map { |original| original.slice('path') })
      end

      def discard_committed_journal
        File.unlink(journal_path)
      rescue SystemCallError
        # The change stands; the next apply or recover removes the committed journal.
        nil
      end

      def validate_originals!(originals, changes)
        paths = changes.map { |entry| entry['path'] }
        return if originals.is_a?(Array) && originals.all?(Hash) && originals.map { |entry| entry['path'] } == paths

        raise Conflict, "Invalid recovery journal; retain it for manual recovery: #{journal_path}"
      end

      def validate_recovery_snapshot!(change)
        return if [change.fetch('before'), Plan.after_fingerprint(change)].include?(current(change))

        raise Conflict,
              "Concurrent edit prevents recovery of #{change.fetch('path')}; journal retained: #{journal_path}"
      end

      def restore_original(original, change)
        return if current(change) == change.fetch('before')

        content = original['content'] && Base64.strict_decode64(original['content']).force_encoding(Encoding::UTF_8)
        expected = { 'sha256' => content && Digest::SHA256.hexdigest(content),
                     'mode' => original.fetch('mode'), 'exists' => !content.nil? }
        assert_snapshot!(expected, change.fetch('before'), original.fetch('path'))
        assert_snapshot!(current(change), Plan.after_fingerprint(change), original.fetch('path'))
        replace(original.fetch('path'), content, original.fetch('mode'))
      end
    end
  end
end
