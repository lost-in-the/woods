# frozen_string_literal: true

module Woods
  module AgentConfiguration
    # Validate every journal snapshot before restoring any managed file.
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
