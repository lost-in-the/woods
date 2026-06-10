# frozen_string_literal: true

require 'json'
require 'fileutils'

module Woods
  module Unblocked
    # Tracks what was last pushed to an Unblocked collection so a sync can
    # skip unchanged documents, re-push changed ones, and delete orphans.
    #
    # The manifest is the local source of truth for change detection: each
    # entry records the content hash of the document we last pushed for a URI
    # plus the remote +document_id+ (needed for deletes). Persisted as JSON
    # alongside the extraction output and restored across CI runs via the CI
    # provider's cache. A missing or corrupt file degrades to "everything is
    # new" — a correct (if expensive) full sync that rebuilds the manifest.
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
      VERSION = 1

      # @param path [String] JSON file path for the manifest
      # @param collection_id [String] Target collection UUID — a stored manifest
      #   for a *different* collection is discarded (cache-key reuse guard).
      def initialize(path:, collection_id:)
        @path = path
        @collection_id = collection_id
        @documents = load
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
        @documents[uri] = { 'hash' => hash, 'document_id' => document_id }
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
        FileUtils.mkdir_p(File.dirname(@path))
        payload = JSON.generate(
          'version' => VERSION,
          'collection_id' => @collection_id,
          'documents' => @documents
        )
        tmp = "#{@path}.tmp"
        File.write(tmp, payload)
        File.rename(tmp, @path)
      end

      private

      # Load the persisted documents, discarding data from a different
      # collection or an unparseable file.
      #
      # @return [Hash{String=>Hash}] uri => { 'hash' =>, 'document_id' => }
      def load
        return {} unless File.exist?(@path)

        parsed = JSON.parse(File.read(@path))
        return {} unless parsed.is_a?(Hash)
        return {} unless parsed['collection_id'] == @collection_id

        documents = parsed['documents']
        documents.is_a?(Hash) ? documents : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
