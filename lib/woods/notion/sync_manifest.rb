# frozen_string_literal: true

require 'json'
require 'digest'

require_relative '../atomic_file'

module Woods
  module Notion
    # Tracks what was last written to the Notion databases so a sync can
    # skip unchanged pages entirely (zero API calls) and PATCH changed ones
    # by cached page id (one call, no find-by-title query). Modeled on
    # {Woods::Unblocked::SyncManifest} (#207 / B-095).
    #
    # Entries are grouped by scope — one scope per Notion database
    # ("data_models", "columns") — and keyed by the page's logical identity:
    # the qualified title from #149 ("users.id" for columns, the table name
    # or "<table> (<Model>)" for data models). Each entry records the Notion
    # page_id plus a deterministic content hash of the mapped properties.
    #
    # The manifest is a local cache, never the source of truth: a missing,
    # corrupt, or unreadable file degrades to "everything is new" — a
    # correct (if expensive) full title-lookup sync that rebuilds it. Reads
    # and writes both go through {Woods::AtomicFile} from day one — a bare
    # +File.read+ tags bytes with the process's default external encoding
    # (US-ASCII under +LANG=C+), which broke the Unblocked manifest's
    # degrade contract on non-ASCII content (B-077 / #189).
    #
    # A stored scope is discarded when its recorded database id no longer
    # matches the configured one (the analog of Unblocked's collection
    # guard): cached page_ids point into the *old* database, and a PATCH by
    # page id would silently write pages the configured database never sees.
    #
    # @example
    #   manifest = SyncManifest.new(path: "tmp/woods/notion_sync_manifest.json",
    #                               database_ids: { data_models: "db-uuid" })
    #   hash = SyncManifest.content_hash(properties)
    #   manifest.unchanged?("data_models", "users", hash) # => false on first run
    #   manifest.record(scope: "data_models", key: "users", hash: hash, page_id: "page-1")
    #   manifest.save
    #
    class SyncManifest
      VERSION = 1

      # Deterministic fingerprint of a mapped Notion properties payload.
      #
      # Hash keys are sorted recursively (after +to_s+, so a symbol-keyed and
      # a string-keyed payload that serialize identically hash identically),
      # so the digest never depends on insertion order. Array order is
      # preserved — it is meaningful in Notion payloads (rich text runs,
      # relation lists).
      #
      # @param properties [Hash] Mapper output (Notion page properties)
      # @return [String] SHA-256 hex digest
      def self.content_hash(properties)
        Digest::SHA256.hexdigest(JSON.generate(canonicalize(properties)))
      end

      # Recursively sort hash keys so serialization is order-independent.
      #
      # @api private
      # @param value [Object]
      # @return [Object]
      def self.canonicalize(value)
        case value
        when Hash
          value.map { |k, v| [k.to_s, canonicalize(v)] }.sort_by(&:first).to_h
        when Array
          value.map { |element| canonicalize(element) }
        else
          value
        end
      end

      # @param path [String] JSON file path for the manifest
      # @param database_ids [Hash{Symbol,String=>String}, nil] Scope name =>
      #   Notion database UUID currently configured. A stored scope whose
      #   recorded database id differs is discarded on load.
      def initialize(path:, database_ids:)
        @path = path
        @database_ids = normalize_database_ids(database_ids)
        @pages = load
      end

      # @return [Boolean] true when no pages are recorded in any scope
      def empty?
        @pages.values.all?(&:empty?)
      end

      # @return [Integer] number of recorded pages across all scopes
      def size
        @pages.values.sum(&:size)
      end

      # @param scope [String] Scope name (e.g. "data_models")
      # @param key [String] Logical page key (qualified title)
      # @param hash [String] Content hash of the properties we would write now
      # @return [Boolean] true when the recorded hash matches *and* a page_id
      #   is on record (without one, a skip would leave dependent pages —
      #   column Table relations — unable to reference the page)
      def unchanged?(scope, key, hash)
        entry = @pages.dig(scope, key)
        !entry.nil? && entry['hash'] == hash && !entry['page_id'].nil?
      end

      # @param scope [String] Scope name
      # @param key [String] Logical page key
      # @return [String, nil] Stored Notion page_id, if known
      def page_id_for(scope, key)
        @pages.dig(scope, key, 'page_id')
      end

      # Record (or update) what we wrote for a page.
      #
      # @param scope [String] Scope name
      # @param key [String] Logical page key (qualified title)
      # @param hash [String] Content hash written
      # @param page_id [String] Notion page UUID
      # @return [void]
      def record(scope:, key:, hash:, page_id:)
        (@pages[scope] ||= {})[key] = { 'hash' => hash, 'page_id' => page_id }
      end

      # Drop one key from a scope (e.g. after a cached page turned out to be
      # deleted in Notion, so the next attempt goes through find-by-title).
      #
      # @param scope [String] Scope name
      # @param key [String] Logical page key
      # @return [void]
      def forget(scope, key)
        @pages[scope]&.delete(key)
      end

      # Drop every key in +scope+ absent from +current_keys+ — pages whose
      # logical identity vanished from the sync set. Only the manifest entry
      # is dropped: the Notion page itself is deliberately left alone (there
      # is no deletion path), pruning just keeps the manifest from growing
      # forever. A key that later reappears goes through the find-by-title
      # path and re-adopts the surviving page.
      #
      # @param scope [String] Scope name
      # @param current_keys [Array<String>, Set] Keys that still exist this run
      # @return [Array<String>] the pruned keys
      def prune(scope, current_keys)
        scoped = @pages[scope]
        return [] unless scoped

        stale = scoped.keys - current_keys.to_a
        stale.each { |key| scoped.delete(key) }
        stale
      end

      # Persist the manifest crash-safely ({Woods::AtomicFile} — temp file,
      # fsync, rename) so an interrupted write never leaves a torn file.
      #
      # @return [void]
      def save
        payload = JSON.generate(
          'version' => VERSION,
          'databases' => @database_ids,
          'pages' => @pages
        )
        AtomicFile.write(@path, payload)
      end

      private

      # @param database_ids [Hash, nil]
      # @return [Hash{String=>String}] string keys/values, nil values dropped
      def normalize_database_ids(database_ids)
        (database_ids || {}).each_with_object({}) do |(scope, id), normalized|
          normalized[scope.to_s] = id.to_s unless id.nil?
        end
      end

      # Load the persisted pages, discarding data from a different schema
      # version or an unparseable/unreadable file, and discarding any scope
      # recorded against a different database id. Every discard warns to
      # stderr — the consequence (a full title-lookup re-check) is expensive
      # enough that operators need to know why it happened.
      #
      # {Woods::AtomicFile.read}, not +File.read+ — see the class docs and
      # B-077. Read failures (e.g. +Errno::EACCES+) take the same discard
      # path: the manifest is a cache, and "everything is new" is always a
      # correct answer.
      #
      # @return [Hash{String=>Hash}] scope => { key => { 'hash' =>, 'page_id' => } }
      def load
        return {} unless File.exist?(@path)

        parsed = JSON.parse(AtomicFile.read(@path))
        return discard('not a JSON object') unless parsed.is_a?(Hash)
        return discard("schema version #{parsed['version'].inspect}, expected #{VERSION}") unless
          parsed['version'] == VERSION

        select_current_scopes(parsed)
      rescue JSON::ParserError
        discard('unparseable JSON')
      rescue EncodingError, SystemCallError => e
        discard("unreadable file: #{e.class}: #{e.message}")
      end

      # Keep only scopes whose recorded database id matches the configured
      # one — cached page_ids from a different database must not be PATCHed.
      #
      # @param parsed [Hash] the persisted manifest document
      # @return [Hash{String=>Hash}]
      def select_current_scopes(parsed)
        pages = parsed['pages']
        return discard('malformed pages section') unless pages.is_a?(Hash)

        stored_dbs = parsed['databases'].is_a?(Hash) ? parsed['databases'] : {}
        pages.each_with_object({}) do |(scope, entries), kept|
          scoped = load_scope(scope, entries, stored_dbs)
          kept[scope] = scoped if scoped
        end
      end

      # One stored scope: kept (minus individually torn entries) when it was
      # recorded against the configured database id, dropped with a warning
      # otherwise.
      #
      # @param scope [String] Scope name from the persisted manifest
      # @param entries [Object] Persisted entries for the scope
      # @param stored_dbs [Hash] Persisted scope => database id map
      # @return [Hash, nil] entries to keep, or nil to drop the scope
      def load_scope(scope, entries, stored_dbs)
        return nil unless entries.is_a?(Hash)
        return entries.select { |_key, entry| entry.is_a?(Hash) } if current_scope?(scope, stored_dbs)

        warn_scope_discard(scope, stored_dbs[scope]) unless entries.empty?
        nil
      end

      # @return [Boolean] true when the stored scope was recorded against the
      #   database id configured now (and one is configured at all)
      def current_scope?(scope, stored_dbs)
        !@database_ids[scope].nil? && stored_dbs[scope] == @database_ids[scope]
      end

      # @param scope [String] Scope being discarded
      # @param stored_id [String, nil] Database id the scope was recorded against
      # @return [void]
      def warn_scope_discard(scope, stored_id)
        warn "WARNING: discarding notion sync manifest scope #{scope.inspect} at #{@path} (written for " \
             "database #{stored_id.inspect}, expected #{@database_ids[scope].inspect}) — " \
             'next sync re-checks those pages by title'
      end

      # @param reason [String] Why the persisted manifest is unusable
      # @return [Hash] empty pages hash (degrades to a full title-lookup sync)
      def discard(reason)
        warn "WARNING: discarding notion sync manifest at #{@path} (#{reason}) — next sync re-checks every page"
        {}
      end
    end
  end
end
