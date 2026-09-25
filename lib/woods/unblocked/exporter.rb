# frozen_string_literal: true

require 'set'
require 'digest'
require 'uri'
require 'woods'
require_relative 'client'
require_relative 'rate_limiter'
require_relative 'document_builder'
require_relative 'sync_manifest'
require_relative 'uri_migration'
require_relative '../export/typed_reader'

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
    # manifest rebuilds current receipts without adopting remote deletion rights.
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
                     manifest: nil, force_full: false, force_purge: false, output: $stdout,
                     migrate_from_ref: nil, dry_run: false)
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
        @typed_reader = Export::TypedReader.new(@reader)
        # Cite the ref the index was actually extracted from. `main` was
        # hardcoded, so citations on a `master`-default repo pointed at a
        # branch that need not exist.
        @repo_url = repo_url.chomp('/')
        @migrate_from_ref = migrate_from_ref
        @dry_run = dry_run
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
        prepared = false
        @stats = nil
        with_prepared_index do
          prepared = true
          @current_uris = Set.new
          @attempted_uris = Set.new
          @budget_exhausted = false
          return preview if @dry_run

          synced = 0
          skipped = 0
          errors = []

          FULL_SYNC_TYPES.each do |type|
            break if @budget_exhausted
            next if type.start_with?('graphql_') # the family already includes these actual types

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

          unless @budget_exhausted || errors.any?
            pending = @migration.plan.map { |move| move['new_uri'] }.compact.to_set - @attempted_uris
            replacements = @published_units.select { |unit| unit['file_path'] && pending.include?(effective_uri(unit)) }
            result = sync_unit_data(replacements.map { |unit| [unit, unit] })
            synced += result[:synced]
            skipped += result[:skipped]
            errors.concat(result[:errors])
          end

          deleted = 0
          unless @budget_exhausted || @ambiguous_uris.any? || errors.any?
            deleted = purge_stale(errors)
            deleted += @migration.cleanup(current_uris: @current_uris, errors: errors,
                                          replacement_hashes: migration_hashes, remote_documents: @remote_documents,
                                          collection_id: @collection_id)
          end
          if @manifest.unresolved_legacy_ownership?
            errors << 'cleanup incomplete: legacy owned documents remain; select their source ref with ' \
                      'UNBLOCKED_MIGRATE_FROM_REF, or review obsolete remote documents and the legacy manifest ' \
                      'receipts for manual cleanup'
          end
          @stats = { synced: synced, skipped: skipped, deleted: deleted, errors: cap_errors(errors),
                     complete: errors.empty? && !@budget_exhausted && @migration.plan.empty? }
        end
      ensure
        save_manifest if prepared && !@dry_run
      end

      # Sync all units of a given type.
      #
      # @param type [String] Unit type (e.g. "model", "controller")
      # @return [Hash] { synced:, skipped:, errors: }
      def sync_type(type)
        with_prepared_index do
          return preview if @dry_run

          units = units_for(type)
          log "  #{type}: #{units.size} units"

          sync_unit_data(units.map { |unit| [unit, unit] })
        end
      end

      # Sync the top N most-connected units of a type (by dependent count).
      #
      # @param type [String] Unit type
      # @param max_count [Integer] Maximum units to sync
      # @return [Hash] { synced:, skipped:, errors: }
      def sync_type_partial(type, max_count)
        with_prepared_index do
          return preview if @dry_run

          units = units_for(type)
          units.each { |unit| track_uri(unit) }
          top = units.sort_by { |unit| -(unit['dependents'] || []).size }.first(max_count)
          log "  #{type}: #{top.size}/#{units.size} units (top by dependents)"
          result = sync_unit_data(top.map { |unit| [unit, unit] })
          result[:skipped] += units.size - top.size
          result
        end
      end

      private

      # Complete preflight precedes all remote writes and destructive pruning.
      # Nested sync methods share this snapshot; standalone methods pin as well.
      def with_prepared_index
        return yield if @prepared_index

        with_pinned_index do
          @builder = DocumentBuilder.new(repo_url: @repo_url, ref: extracted_ref)
          @published_units = @typed_reader.all
          build_uri_index
          @manifest.activate_scope(repo_url: @repo_url, ref: @builder.ref,
                                   current_uris: @published_units.filter_map do |unit|
                                     effective_uri(unit) if unit['file_path']
                                   end)
          @migration = UriMigration.new(manifest: @manifest, client: @client, from_ref: @migrate_from_ref,
                                        replacements: migration_replacements)
          unless @dry_run
            inventory = @client.all_documents(collection_id: nil)
            @remote_documents = inventory.each_with_object({}) do |doc, documents|
              uri = doc['uri']
              documents[uri] = doc if uri.is_a?(String) && !uri.empty?
            end
          end
          @prepared_index = true
          begin
            yield
          ensure
            @prepared_index = false
            @published_units = nil
          end
        end
      end

      def units_for(type)
        # The historical graphql family includes all four actual subtypes.
        types = type == 'graphql' ? MCP::IndexReader::UNIT_TYPES_BY_DIR.fetch('graphql') : [type]
        @published_units.select { |unit| types.include?(unit['type']) }
      end

      # Run a multi-read export body against one index generation.
      #
      # Every public IndexReader accessor self-refreshes when the published
      # generation moves, and the reader assigns pinning responsibility to
      # direct callers. Unpinned, `build_uri_index`, the per-type listings and
      # `purge_stale` can straddle two generations (EXP-5), so the purge set is
      # computed against a mixture of them.
      #
      # Guarded by +respond_to?+: injected readers (specs, embedders) need not
      # implement pinning.
      #
      # @yield the export body
      # @return [Object] the block's value
      def with_pinned_index(&block)
        return yield unless @reader.respond_to?(:with_pinned_generation)

        @reader.with_pinned_generation(&block)
      end

      def sync_unit_data(entries_with_data)
        synced = 0
        skipped = 0
        errors = []

        entries_with_data.each do |entry, unit_data|
          track_uri(unit_data)
          (@attempted_uris ||= Set.new).add(effective_uri(unit_data)) if unit_data['file_path']
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
        if @ambiguous_uris.include?(@builder.uri_for(unit_data))
          raise ExtractionError,
                "ambiguous export URI for #{unit_data['type']}:#{unit_data['identifier']} — push skipped"
        end
        # No file_path → the URI falls back to the bare repo URL, which every
        # such unit would share: they'd overwrite each other remotely and
        # ping-pong the manifest hash forever. Skip them.
        return :skipped unless unit_data['file_path']

        # When several units share one file they share one base URI; only one
        # keeps it, the rest get a `?unit=` suffix so each is a distinct remote
        # document (and a distinct manifest key).
        uri = effective_uri(unit_data)
        remote = @remote_documents && @remote_documents[uri]
        if remote && remote['collectionId'] != @collection_id
          raise Woods::ExtractionError, 'export URI belongs to a different remote collection — push refused'
        end

        doc = @builder.build(unit_data)
        # An empty body means the credential scrub failed closed (the builders
        # always emit at least a header). Upserting it would overwrite a good
        # remote document with nothing — error out and leave the remote as-is.
        if doc[:body].nil? || doc[:body].empty?
          raise Woods::ExtractionError, 'document body empty (credential scrub failure?) — push skipped'
        end

        hash = fingerprint(doc)
        remote_matches = remote && remote['id'] && remote['id'] == @manifest.document_id_for(uri)
        return :skipped if !@force_full && remote_matches && @manifest.unchanged?(uri, hash)

        response = @client.put_document(
          collection_id: @collection_id,
          title: doc[:title],
          body: doc[:body],
          uri: uri
        )
        document_id = (response['id'] if response.is_a?(Hash)) || remote&.fetch('id', nil)
        @remote_documents[uri] = { 'uri' => uri, 'id' => document_id, 'collectionId' => @collection_id }
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

        if guard_blocks_purge?(stale)
          errors << 'cleanup incomplete: mass-deletion guard refused stale documents'
          return 0
        end

        resolve_missing_document_ids(stale)

        deleted = 0
        stale.each do |uri|
          remote = @remote_documents[uri]
          unless remote
            @manifest.forget(uri)
            next
          end
          document_id = @manifest.document_id_for(uri)
          unless document_id
            errors << "cleanup incomplete: remote document ID unresolved for #{uri}"
            next
          end

          unless remote['id'] == document_id && remote['collectionId'] == @collection_id
            errors << "cleanup incomplete: remote identity/collection changed for #{uri}"
            next
          end

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

        ids_by_uri = @remote_documents.values.select { |doc| doc['collectionId'] == @collection_id }
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

      # A preview reads published data and local ownership only. It makes no
      # remote requests and never persists the in-memory migration plan.
      def preview
        { synced: 0, skipped: 0, deleted: 0, errors: [], complete: false, dry_run: true,
          migration: @migration.plan, scope: { repo_url: @repo_url, ref: @builder.ref } }
      end

      def migration_replacements
        return {} unless @migrate_from_ref

        legacy_builder = DocumentBuilder.new(repo_url: @repo_url, ref: @migrate_from_ref)
        @published_units.each_with_object({}) do |unit, mapping|
          next unless unit['file_path']
          next if @ambiguous_uris.include?(@builder.uri_for(unit))

          old_base = legacy_builder.uri_for(unit)
          old_raw = old_base.sub("/blob/#{encode_ref(@migrate_from_ref)}/", "/blob/#{@migrate_from_ref}/")
          suffix = effective_uri(unit).delete_prefix(@builder.uri_for(unit))
          # A v1 bare URI has no typed owner receipt. A new sibling may now
          # own that bare URI; do not guess which historical unit it replaced.
          next if suffix.empty? && @uri_primary.key?(@builder.uri_for(unit))

          [old_base, old_raw].uniq.each { |base| mapping[base + suffix] = effective_uri(unit) }
        end
      end

      def migration_hashes
        pending = @migration.plan.map { |move| move['new_uri'] }.compact.to_set
        @published_units.each_with_object({}) do |unit, hashes|
          next unless unit['file_path']

          uri = effective_uri(unit)
          next unless pending.include?(uri)

          document = @builder.build(unit)
          hashes[uri] = fingerprint(document) unless document[:body].to_s.empty?
        end
      end

      def encode_ref(ref)
        ref.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')
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

      # Inspect the complete validated snapshot, including excluded types, for
      # same-name cross-type collisions. For files with distinct synced names,
      # the lexically-smallest identifier — the
      # outer/top-level class — keeps the bare URI; siblings are suffixed. Solo
      # files (the overwhelming majority) are absent from the map and unchanged,
      # so this introduces no churn for them.
      def build_uri_index
        groups = Hash.new { |h, k| h[k] = [] }
        @published_units.each do |unit|
          next unless unit['file_path']

          groups[@builder.uri_for(unit)] << unit
        end

        @ambiguous_uris = groups.each_with_object(Set.new) do |(uri, units), ambiguous|
          identities = units.map { |unit| [unit['identifier'], unit['type']] }.uniq
          ambiguous << uri if identities.group_by(&:first).any? { |_, variants| variants.size > 1 }
        end
        @uri_primary = groups.each_with_object({}) do |(uri, units), primary|
          unique = units.select { |unit| synced_types.include?(unit['type']) }.map { |unit| unit['identifier'] }.uniq
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
        return false unless error.is_a?(BudgetExhaustedError) || error.message.include?('budget exhausted for this run')

        @budget_exhausted = true
      end

      def build_reader(index_dir)
        require_relative '../mcp/index_reader'
        Woods::MCP::IndexReader.new(index_dir)
      end

      # The git ref recorded in the index manifest, for citation URLs.
      #
      # Nil on any failure — a missing or unreadable manifest must not stop a
      # sync, and DocumentBuilder falls back to its default ref.
      #
      # @return [String, nil]
      def extracted_ref
        @reader.manifest['git_branch']
      rescue StandardError
        nil
      end

      # Persist receipts without masking an in-flight exception. A failed save
      # leaves completion false: cleanup requires durable ownership evidence.
      def save_manifest
        @manifest.save
      rescue StandardError => e
        message = "sync manifest not persisted: #{e.class}: #{e.message}"
        @stats[:errors] << message if @stats
        @stats[:complete] = false if @stats
        log "  WARNING: #{message} — recover local ownership state before cleanup"
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
