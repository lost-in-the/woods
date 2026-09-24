# frozen_string_literal: true

module Woods
  module Unblocked
    # Resumable, explicitly selected URI replacements. Ordinary branch changes
    # never enter this path and never retire another branch's ownership scope.
    class UriMigration
      # @param manifest [SyncManifest] currently selected target scope
      # @param client [Client] remote document operations
      # @param from_ref [String, nil] explicit source branch, or resume pending work
      # @param replacements [Hash{String => String}] old URI to published target URI
      def initialize(manifest:, client:, from_ref:, replacements:)
        @manifest = manifest
        @client = client
        return unless from_ref

        moves = manifest.migration_sources(from_ref: from_ref).filter_map do |entry|
          target = replacements[entry.fetch('old_uri')]
          next if target == entry.fetch('old_uri')

          entry.merge('new_uri' => target)
        end
        manifest.start_migration(from_ref: from_ref, moves: moves)
      end

      # @return [Array<Hash>] exact pending replacements, suitable for preview
      def plan
        @manifest.migration&.fetch('moves') || []
      end

      # Save successful replacement receipts before deleting any old copies.
      # This explicit migration set has its own ownership checks; the ordinary
      # mass-delete ratio does not mistake a one-for-one migration for loss.
      # @param current_uris [Set<String>] verified current publication membership
      # @param errors [Array<String>] actionable refusal/failure messages
      # @return [Integer] old copies removed
      def cleanup(current_uris:, errors:, replacement_hashes:, remote_documents:, collection_id:)
        return 0 if plan.empty?

        @manifest.save
        deleted = 0
        plan.dup.each do |move|
          remote = remote_documents[move.fetch('old_uri')]
          if remote.nil?
            finish_move(move)
            next
          end
          reason = refusal(move, current_uris, replacement_hashes)
          target = remote_documents[move['new_uri']]
          unless target && target['id'] == @manifest.document_id_for(move['new_uri']) &&
                 target['collectionId'] == collection_id
            reason ||= 'replacement remote identity is missing or changed'
          end
          reason ||= 'source remote identity/collection changed; review before cleanup' unless
            remote['id'] == move['document_id'] && remote['collectionId'] == collection_id
          if reason
            errors << "URI migration incomplete: #{reason} (#{move.fetch('old_uri')})"
            next
          end
          @client.delete_document(document_id: move.fetch('document_id'))
          deleted += 1
          finish_move(move)
        rescue ApiError => e
          if e.status == 404
            finish_move(move)
          else
            errors << "URI migration cleanup failed: #{e.message}"
          end
        rescue StandardError => e
          errors << "URI migration cleanup incomplete: #{e.class}: #{e.message}"
          break
        end
        @manifest.finish_migration
        deleted
      end

      private

      def refusal(move, current_uris, replacement_hashes)
        unless move['owned'] == true
          return 'legacy ownership is unverified; review the remote record before manual cleanup'
        end
        unless move['document_id'].is_a?(String) && !move['document_id'].empty?
          return 'source document ID is unresolved'
        end
        return 'no unambiguous current replacement' unless current_uris.include?(move['new_uri'])

        expected = replacement_hashes[move['new_uri']]
        return 'replacement content has not been successfully synchronized' unless
          expected && @manifest.unchanged?(move['new_uri'], expected)

        target_id = @manifest.document_id_for(move['new_uri'])
        return 'replacement has no persisted successful document receipt' unless target_id
        return 'source and replacement document IDs are identical' if target_id == move['document_id']

        nil
      end

      def finish_move(move)
        @manifest.complete_move(move)
        @manifest.save
      end
    end
  end
end
