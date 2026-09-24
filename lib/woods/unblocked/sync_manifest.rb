# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require 'erb'

require_relative '../atomic_file'

module Woods
  module Unblocked
    # Tracks what was last pushed to an Unblocked collection so a sync can
    # skip unchanged documents, re-push changed ones, and delete orphans.
    #
    # The manifest is the local source of truth for change detection: each
    # entry records the content hash of the document we last pushed for a URI
    # plus the remote +document_id+ (needed for deletes). Persisted as JSON
    # alongside the extraction output and restored across CI runs via the CI
    # provider's cache. Missing receipts never establish remote deletion rights.
    # Corrupt or mismatched manifests require recovery before another sync.
    #
    # Modeled on the embedding indexer's checkpoint (load JSON → compare
    # per-key hash → save JSON).
    #
    # @example
    #   manifest = SyncManifest.new(path: "tmp/woods/unblocked_sync_manifest.json",
    #                               collection_id: "col-uuid")
    #   manifest.unchanged?(uri, hash)  # => false on first run
    #   manifest.record(uri:, hash:, document_id:)
    #   manifest.save
    #
    class SyncManifest
      VERSION = 2

      # @param path [String] JSON file path for the manifest
      # @param collection_id [String] Target collection UUID — a stored manifest
      #   for a *different* collection is discarded (cache-key reuse guard).
      def initialize(path:, collection_id:)
        @path = path
        @collection_id = collection_id
        @scopes = {}
        @documents = load
        @legacy_documents = @documents
        @documents = @scopes.dig(@active_scope, 'documents') || @legacy_documents
      end

      # @return [Boolean] true when no documents are recorded
      def empty?
        @documents.empty?
      end

      # @param uri [String] Document URI
      # @param hash [String] Content hash of the document we would push now
      # @return [Boolean] true when the recorded hash matches (safe to skip)
      def unchanged?(uri, hash)
        entry = @documents[uri]
        !entry.nil? && entry['hash'] == hash
      end

      # Record (or update) what we pushed for a URI.
      #
      # @param uri [String] Document URI
      # @param hash [String, nil] Content hash pushed (nil forces a future re-push)
      # @param document_id [String, nil] Remote document UUID (for later deletes)
      def record(uri:, hash:, document_id:)
        owned = !hash.nil? || @documents.dig(uri, 'owned') == true
        @documents[uri] = { 'hash' => hash, 'document_id' => document_id, 'owned' => owned }
      end

      # @param uri [String] Document URI
      # @return [String, nil] Stored remote document_id, if known
      def document_id_for(uri)
        @documents.dig(uri, 'document_id')
      end

      # URIs we have a record of that are absent from the current run's set.
      #
      # @param current_uris [Array<String>, Set] URIs that still exist this run
      # @return [Array<String>] recorded URIs no longer present (deletion candidates)
      def stale_uris(current_uris)
        present = current_uris.to_a
        @documents.keys - present
      end

      # @return [Integer] number of recorded documents
      def size
        @documents.size
      end

      # Drop a URI from the manifest (after a successful remote delete).
      #
      # @param uri [String] Document URI
      def forget(uri)
        @documents.delete(uri)
      end

      # Persist the manifest atomically (temp file + rename) so an interrupted
      # write never leaves a torn file in the CI cache.
      def save
        payload = JSON.generate(
          'version' => VERSION,
          'collection_id' => @collection_id,
          'documents' => @legacy_documents,
          'scopes' => @scopes,
          'active_scope' => @active_scope
        )
        AtomicFile.write(@path, payload)
      end

      # Select one repository/ref without retiring any other branch's documents.
      # Existing v1 entries are adopted only when they prove a successful write
      # and correspond to a currently published URI in this exact scope.
      def activate_scope(repo_url:, ref:, current_uris:)
        raise Woods::ConfigurationError, "Unblocked manifest needs recovery: #{@load_error}" if @load_error

        @repo_url = repo_url.chomp('/')
        @ref = ref
        @active_scope = scope_key(@repo_url, ref)
        @scopes[@active_scope] ||= { 'repo_url' => @repo_url, 'ref' => ref, 'documents' => {} }
        @documents = @scopes.fetch(@active_scope).fetch('documents')
        current_uris.each do |uri|
          entry = @legacy_documents[uri]
          next unless entry && owned?(entry)

          @documents[uri] ||= entry
          @legacy_documents.delete(uri)
        end
      end

      # Local ownership evidence for an explicitly selected migration source.
      # A remote listing never establishes permission to delete a document.
      def migration_sources(from_ref:)
        key = scope_key(@repo_url, from_ref)
        scoped = @scopes.dig(key, 'documents') || {}
        prefixes = [from_ref, encode_ref(from_ref)].uniq.map { |ref| "#{@repo_url}/blob/#{ref}/" }
        legacy = @legacy_documents.select { |uri, _| prefixes.any? { |prefix| uri.start_with?(prefix) } }
        [[:legacy, legacy], [key, scoped]].flat_map do |location, entries|
          entries.map do |uri, entry|
            entry.merge('old_uri' => uri, 'source_scope' => location.to_s, 'owned' => owned?(entry))
          end
        end
      end

      # Persist the approved source scope and bounded set of replacement pairs.
      def start_migration(from_ref:, moves:)
        current = migration
        if current && current['from_ref'] != from_ref
          raise Woods::ConfigurationError, 'Finish the pending Unblocked migration before selecting another source ref'
        end

        @scopes.fetch(@active_scope)['migration'] ||= { 'from_ref' => from_ref, 'moves' => moves }
      end

      def migration
        @scopes.dig(@active_scope, 'migration')
      end

      def complete_move(move)
        source = if move.fetch('source_scope') == 'legacy'
                   @legacy_documents
                 else
                   @scopes.dig(move.fetch('source_scope'), 'documents')
                 end
        source&.delete(move.fetch('old_uri'))
        migration.fetch('moves').delete(move)
      end

      # Finish only after every selected replacement and old-copy cleanup.
      def finish_migration
        @scopes.fetch(@active_scope).delete('migration') if migration && migration.fetch('moves').empty?
      end

      private

      def scope_key(repo, ref)
        Digest::SHA256.hexdigest(JSON.generate([repo, ref]))
      end

      def encode_ref(ref)
        ref.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')
      end

      def owned?(entry)
        entry['owned'] == true || (entry['hash'].is_a?(String) && !entry['hash'].empty?)
      end

      def valid_documents?(documents)
        documents.is_a?(Hash) && documents.all? { |uri, entry| uri.is_a?(String) && entry.is_a?(Hash) }
      end

      def valid_scopes?(scopes)
        scopes.is_a?(Hash) && scopes.all? do |key, scope|
          key.is_a?(String) && scope.is_a?(Hash) && scope['repo_url'].is_a?(String) &&
            scope['ref'].is_a?(String) && key == scope_key(scope['repo_url'], scope['ref']) &&
            valid_documents?(scope['documents']) && valid_migration?(scope['migration'])
        end
      end

      def valid_migration?(migration)
        return true if migration.nil?
        unless migration.is_a?(Hash) && migration['from_ref'].is_a?(String) && migration['moves'].is_a?(Array)
          return false
        end

        migration['moves'].all? do |move|
          move.is_a?(Hash) && move['old_uri'].is_a?(String) && move['source_scope'].is_a?(String) &&
            (move['new_uri'].nil? || move['new_uri'].is_a?(String)) && [true, false].include?(move['owned'])
        end
      end

      # Retain legacy records, but refuse malformed ownership state at sync
      # preflight. AtomicFile supplies UTF-8 independently of the host locale.
      # @return [Hash{String=>Hash}] uri => { 'hash' =>, 'document_id' => }
      def load
        return {} unless File.exist?(@path)

        parsed = JSON.parse(AtomicFile.read(@path))
        return discard('not a JSON object') unless parsed.is_a?(Hash)
        return discard("schema version #{parsed['version'].inspect}, expected 1 or #{VERSION}") unless
          [1, VERSION].include?(parsed['version'])
        return discard("written for collection #{parsed['collection_id'].inspect}, expected #{@collection_id}") unless
          parsed['collection_id'] == @collection_id

        @scopes = parsed.fetch('scopes', {})
        return discard('invalid scoped ownership records') unless valid_scopes?(@scopes)

        @active_scope = parsed['active_scope']
        documents = parsed['documents']
        return discard('invalid document ownership records') unless valid_documents?(documents)

        documents
      rescue JSON::ParserError
        discard('unparseable JSON')
      rescue EncodingError, SystemCallError => e
        discard("unreadable file: #{e.class}: #{e.message}")
      end

      # @param reason [String] Why the persisted manifest is unusable
      # @return [Hash] empty documents hash (degrades to a full re-push)
      def discard(reason)
        @load_error = reason
        @scopes = {}
        warn "WARNING: discarding sync manifest at #{@path} (#{reason}) — " \
             'sync requires manifest recovery before remote changes'
        {}
      end
    end
  end
end
