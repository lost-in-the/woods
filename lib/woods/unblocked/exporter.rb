# frozen_string_literal: true

require 'set'
require 'digest'
require 'uri'
require 'woods'
require_relative 'client'
require_relative 'rate_limiter'
require_relative 'document_builder'
require_relative 'sync_manifest'

module Woods
  module Unblocked
    # Orchestrates syncing Woods extraction data to an Unblocked collection.
    #
    # Reads extraction output from disk via IndexReader, converts units to
    # condensed Markdown documents, and pushes via the Unblocked Documents API.
    # Syncs are incremental: a {SyncManifest} records the content hash and
    # remote document_id of everything last pushed, so each run only PUTs
    # new/changed documents, skips unchanged ones, and deletes documents whose
    # source unit has disappeared. Documents are upserted by URI, so a missing
    # manifest (first run / CI cache miss) degrades to a correct full sync.
    #
    # @example
    #   exporter = Exporter.new(index_dir: "tmp/woods")
    #   stats = exporter.sync_all
    #   # => { synced: 12, skipped: 928, deleted: 1, errors: [] }
    #
    class Exporter
      MAX_ERRORS = 100

      # Mass-deletion guard: refuse to purge when more than this fraction of a
      # manifest of at least PURGE_GUARD_MIN_DOCS entries would be deleted —
      # the signature of a sync run against a partial index. Override with
      # force_purge.
      PURGE_GUARD_FRACTION = 0.30
      PURGE_GUARD_MIN_DOCS = 10

      # Unit types to sync, in priority order.
      # All units are synced for these types.
      FULL_SYNC_TYPES = %w[
        model controller service job mailer manager decorator concern serializer
        graphql graphql_type graphql_mutation graphql_resolver graphql_query
      ].freeze

      # Unit types where only the most-connected units are synced.
      # Each entry: [type, max_count]
      PARTIAL_SYNC_TYPES = [
        ['poro', 100],
        ['lib', 50]
      ].freeze

      # @param index_dir [String] Path to extraction output directory
      # @param config [Configuration] Woods configuration (default: global config)
      # @param client [Client, nil] Unblocked API client (auto-created from config if nil)
      # @param reader [Object, nil] IndexReader instance (auto-created if nil)
      # @param manifest [SyncManifest, nil] Sync manifest (auto-created under index_dir if nil)
      # @param force_full [Boolean] Re-push every unit, ignoring the unchanged check
      # @param force_purge [Boolean] Bypass the mass-deletion guard
      # @param output [IO] Progress output stream (default: $stdout)
      # @raise [ConfigurationError] if required config is missing
      def initialize(index_dir:, config: Woods.configuration, client: nil, reader: nil,
                     manifest: nil, force_full: false, force_purge: false, output: $stdout)
        @collection_id = config.unblocked_collection_id
        raise ConfigurationError, 'unblocked_collection_id is required' unless @collection_id

        repo_url = config.unblocked_repo_url
        raise ConfigurationError, 'unblocked_repo_url is required' unless repo_url

        api_token = config.unblocked_api_token
        raise ConfigurationError, 'unblocked_api_token is required' unless api_token

        budget = ENV.fetch('UNBLOCKED_DAILY_BUDGET', RateLimiter::DEFAULT_BUDGET.to_s).to_i
        limiter = RateLimiter.new(daily_budget: budget)

        @client = client || Client.new(api_token: api_token, rate_limiter: limiter)
        @reader = reader || build_reader(index_dir)
        @builder = DocumentBuilder.new(repo_url: repo_url)
        @manifest = manifest || build_manifest(index_dir)
        @force_full = force_full
        @force_purge = force_purge
        @output = output
        # Initialized here as well as in sync_all so the public sync_type /
        # sync_type_partial methods work standalone (track_uri needs them).
        @current_uris = Set.new
        @budget_exhausted = false
        # base URI => identifier that keeps the bare URI (only populated for
        # URIs shared by >1 unit). Rebuilt per sync_all run.
        @uri_primary = {}
      end

      # Sync all configured unit types to the Unblocked collection.
      #
      # @return [Hash] { synced:, skipped:, deleted:, errors: }
      def sync_all
        @current_uris = Set.new
        @budget_exhausted = false
        build_uri_index
        reconcile_from_remote if @manifest.empty?

        synced = 0
        skipped = 0
        errors = []

        FULL_SYNC_TYPES.each do |type|
          break if @budget_exhausted

          result = sync_type(type)
          synced += result[:synced]
          skipped += result[:skipped]
          errors.concat(result[:errors])
        end

        PARTIAL_SYNC_TYPES.each do |type, max_count|
          break if @budget_exhausted

          result = sync_type_partial(type, max_count)
          synced += result[:synced]
          skipped += result[:skipped]
          errors.concat(result[:errors])
        end

        deleted = @budget_exhausted ? 0 : purge_stale(errors)
        { synced: synced, skipped: skipped, deleted: deleted, errors: cap_errors(errors) }
      ensure
        save_manifest
      end

      # Sync all units of a given type.
      #
      # @param type [String] Unit type (e.g. "model", "controller")
      # @return [Hash] { synced:, skipped:, errors: }
      def sync_type(type)
        units = @reader.list_units(type: type)
        log "  #{type}: #{units.size} units"

        sync_units(units)
      end

      # Sync the top N most-connected units of a type (by dependent count).
      #
      # @param type [String] Unit type
      # @param max_count [Integer] Maximum units to sync
      # @return [Hash] { synced:, skipped:, errors: }
      def sync_type_partial(type, max_count)
        units = @reader.list_units(type: type)
        return empty_stats if units.empty?

        # Load full data to sort by dependent count
        units_with_data = units.filter_map do |entry|
          data = @reader.find_unit(entry['identifier'])
          next unless data

          dep_count = (data['dependents'] || []).size
          { entry: entry, data: data, dep_count: dep_count }
        end

        # Every unit of this type still exists — track its URI so partial units
        # that fall *out* of the top-N are never mistaken for deletions.
        units_with_data.each { |u| track_uri(u[:data]) }

        top_units = units_with_data.sort_by { |u| -u[:dep_count] }.first(max_count)
        # Count against what was actually synced — units.size includes entries
        # whose unit data was missing (dropped by the filter_map above).
        skipped_count = units.size - top_units.size

        log "  #{type}: #{top_units.size}/#{units.size} units (top by dependents)"

        result = sync_unit_data(top_units.map { |u| [u[:entry], u[:data]] })
        result[:skipped] += skipped_count
        result
      end

      private

      def sync_units(units)
        synced = 0
        skipped = 0
        errors = []

        units.each do |entry|
          unit_data = @reader.find_unit(entry['identifier'])
          unless unit_data
            skipped += 1
            next
          end

          track_uri(unit_data)
          if push_document(unit_data) == :skipped
            skipped += 1
          else
            synced += 1
          end
        rescue Woods::Error => e
          errors << "#{entry['identifier']}: #{e.message}"
          break if note_budget_exhaustion(e)
        rescue StandardError => e
          # Include the class — "undefined method for nil" without it is
          # unactionable in CI logs.
          errors << "#{entry['identifier']}: #{e.class}: #{e.message}"
        end

        { synced: synced, skipped: skipped, errors: errors }
      end

      def sync_unit_data(entries_with_data)
        synced = 0
        skipped = 0
        errors = []

        entries_with_data.each do |entry, unit_data|
          track_uri(unit_data)
          if push_document(unit_data) == :skipped
            skipped += 1
          else
            synced += 1
          end
        rescue Woods::Error => e
          errors << "#{entry['identifier']}: #{e.message}"
          break if note_budget_exhaustion(e)
        rescue StandardError => e
          # Include the class — "undefined method for nil" without it is
          # unactionable in CI logs.
          errors << "#{entry['identifier']}: #{e.class}: #{e.message}"
        end

        { synced: synced, skipped: skipped, errors: errors }
      end

      # Build the document, skip it if the manifest says it is unchanged,
      # otherwise upsert it and record the new hash + remote document_id.
      #
      # @return [Symbol] :synced or :skipped
      def push_document(unit_data)
        # No file_path → the URI falls back to the bare repo URL, which every
        # such unit would share: they'd overwrite each other remotely and
        # ping-pong the manifest hash forever. Skip them.
        return :skipped unless unit_data['file_path']

        # When several units share one file they share one base URI; only one
        # keeps it, the rest get a `?unit=` suffix so each is a distinct remote
        # document (and a distinct manifest key).
        uri = effective_uri(unit_data)

        doc = @builder.build(unit_data)
        # An empty body means the credential scrub failed closed (the builders
        # always emit at least a header). Upserting it would overwrite a good
        # remote document with nothing — error out and leave the remote as-is.
        if doc[:body].nil? || doc[:body].empty?
          raise Woods::ExtractionError, 'document body empty (credential scrub failure?) — push skipped'
        end

        hash = fingerprint(doc)
        return :skipped if !@force_full && @manifest.unchanged?(uri, hash)

        response = @client.put_document(
          collection_id: @collection_id,
          title: doc[:title],
          body: doc[:body],
          uri: uri
        )
        document_id = (response['id'] if response.is_a?(Hash)) || @manifest.document_id_for(uri)
        @manifest.record(uri: uri, hash: hash, document_id: document_id)
        :synced
      end

      # Delete remote documents whose source unit no longer exists. Failures
      # are appended to +errors+ — a delete that fails silently every run is
      # how a collection rots while "deleted: 0" looks normal.
      #
      # @param errors [Array<String>] sink for delete failures
      # @return [Integer] number of documents deleted
      def purge_stale(errors)
        stale = @manifest.stale_uris(@current_uris)
        return 0 if stale.empty?
        return 0 if guard_blocks_purge?(stale)

        resolve_missing_document_ids(stale)

        deleted = 0
        stale.each do |uri|
          document_id = @manifest.document_id_for(uri)
          next unless document_id

          @client.delete_document(document_id: document_id)
          @manifest.forget(uri)
          deleted += 1
        rescue ApiError => e
          if e.status == 404
            # Already gone remotely — goal state reached, drop the entry
            # rather than retrying every run.
            @manifest.forget(uri)
          else
            errors << "delete #{uri}: #{e.message}"
          end
        rescue Woods::Error => e
          break if note_budget_exhaustion(e)

          errors << "delete #{uri}: #{e.message}"
        rescue StandardError => e
          # Entry stays in the manifest so a later run retries the delete —
          # but surface the failure so systematic breakage is visible.
          errors << "delete #{uri}: #{e.class}: #{e.message}"
        end
        deleted
      end

      # A manifest entry can carry a nil document_id (e.g. the PUT response
      # body was empty). Those entries would be permanently undeletable, so
      # before purging, make one bounded all_documents sweep to resolve ids.
      # Best-effort: unresolved entries are simply skipped by the purge loop.
      def resolve_missing_document_ids(stale)
        missing = stale.select { |uri| @manifest.document_id_for(uri).nil? }
        return if missing.empty?

        ids_by_uri = @client.all_documents(collection_id: @collection_id)
                            .to_h { |doc| [doc['uri'], doc['id']] }
        missing.each do |uri|
          id = ids_by_uri[uri]
          @manifest.record(uri: uri, hash: nil, document_id: id) if id
        end
      rescue StandardError => e
        log "  id resolution skipped (#{e.message})"
      end

      # True when purging +stale+ would delete too large a fraction of the
      # manifest — the signature of running against a partial index. The floor
      # (PURGE_GUARD_MIN_DOCS) keeps small collections deletable.
      def guard_blocks_purge?(stale)
        return false if @force_purge

        size = @manifest.size
        return false if size < PURGE_GUARD_MIN_DOCS

        fraction = stale.size.to_f / size
        return false unless fraction > PURGE_GUARD_FRACTION

        log "  WARNING: refusing to delete #{stale.size} of #{size} documents " \
            "(#{(fraction * 100).round}% > #{(PURGE_GUARD_FRACTION * 100).to_i}% — likely a partial index). " \
            'Set UNBLOCKED_FORCE_PURGE=1 to override.'
        true
      end

      # Seed the manifest from the remote collection when we have no local
      # state (first run / CI cache miss). The list endpoint returns no body,
      # so hashes are nil (everything re-pushes), but recovering document_ids
      # lets this run still purge orphaned documents.
      #
      # Auth failures re-raise: a 401/403 here dooms every subsequent call,
      # and "proceeding with full sync" would burn the whole daily budget on
      # guaranteed failures.
      def reconcile_from_remote
        @client.all_documents(collection_id: @collection_id).each do |doc|
          uri = doc['uri']
          next unless uri

          @manifest.record(uri: uri, hash: nil, document_id: doc['id'])
        end
      rescue ApiError => e
        raise if [401, 403].include?(e.status)

        log "  reconcile skipped (#{e.message}) — proceeding with full sync"
      rescue StandardError => e
        log "  reconcile skipped (#{e.message}) — proceeding with full sync"
      end

      def track_uri(unit_data)
        # Units without a file_path are never pushed (see push_document), so
        # their fallback repo-root URI must not be marked current either — a
        # stale repo-root document from before this guard should purge.
        return unless unit_data['file_path']

        # Must match the URI push_document actually uses, or a colliding unit's
        # disambiguated document would look stale and be purged.
        @current_uris << effective_uri(unit_data)
      end

      # The URI a unit's document is stored under. Normally the file's blob URL;
      # when several units share that file, all but the lexically-first
      # identifier get a `?unit=` suffix so each keeps a distinct document
      # rather than overwriting the others (see #build_uri_index).
      def effective_uri(unit_data)
        base = @builder.uri_for(unit_data)
        primary = @uri_primary[base]
        return base if primary.nil? || primary == unit_data['identifier']

        "#{base}?unit=#{URI.encode_www_form_component(unit_data['identifier'])}"
      end

      # One cheap pass over the type indexes (entries already carry file_path,
      # and read_index is cached) to find files that define more than one synced
      # unit. For each such base URI, the lexically-smallest identifier — the
      # outer/top-level class — keeps the bare URI; siblings are suffixed. Solo
      # files (the overwhelming majority) are absent from the map and unchanged,
      # so this introduces no churn for them.
      def build_uri_index
        groups = Hash.new { |h, k| h[k] = [] }
        synced_types.each do |type|
          @reader.list_units(type: type).each do |entry|
            next unless entry['file_path']

            groups[@builder.uri_for(entry)] << entry['identifier']
          end
        end

        @uri_primary = groups.each_with_object({}) do |(uri, identifiers), primary|
          unique = identifiers.uniq
          primary[uri] = unique.min if unique.size > 1
        end
      end

      def synced_types
        FULL_SYNC_TYPES + PARTIAL_SYNC_TYPES.map(&:first)
      end

      def fingerprint(doc)
        Digest::SHA256.hexdigest("#{doc[:title]}\n#{doc[:body]}")
      end

      # Records whether an error was a budget-exhaustion stop. Returns true when
      # it was, so callers can break out of their loop. Class check first; the
      # message match remains as a fallback for injected clients that raise
      # plain Woods::Error.
      def note_budget_exhaustion(error)
        return false unless error.is_a?(BudgetExhaustedError) || error.message.include?('daily budget exhausted')

        @budget_exhausted = true
      end

      def build_reader(index_dir)
        require_relative '../mcp/index_reader'
        Woods::MCP::IndexReader.new(index_dir)
      end

      # Persist the manifest, downgrading failures to a warning: losing the
      # manifest only costs a full re-check next run, which must not turn an
      # otherwise-successful sync into a crash (this runs from an ensure, where
      # a raise would also mask any in-flight exception).
      def save_manifest
        @manifest.save
      rescue StandardError => e
        log "  WARNING: sync manifest not persisted (#{e.message}) — next run will re-push all documents"
      end

      def build_manifest(index_dir)
        SyncManifest.new(
          path: File.join(index_dir, 'unblocked_sync_manifest.json'),
          collection_id: @collection_id
        )
      end

      def empty_stats
        { synced: 0, skipped: 0, errors: [] }
      end

      def cap_errors(errors)
        return errors if errors.size <= MAX_ERRORS

        errors.first(MAX_ERRORS) + ["... and #{errors.size - MAX_ERRORS} more errors"]
      end

      def log(message)
        @output&.puts(message)
      end
    end
  end
end
