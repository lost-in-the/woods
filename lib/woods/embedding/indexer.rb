# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'set'

require_relative '../atomic_file'
require_relative '../generation'
require_relative '../extracted_unit'
require_relative '../chunking/semantic_chunker'
require_relative '../util/uuid5'

module Woods
  # Standalone-require shim (same pattern as Console::Server and
  # Storage::MetadataStore): ChunkSuffixCollision below inherits Woods::Error,
  # which lib/woods.rb defines but an isolated require of this file does not.
  class Error < StandardError; end unless defined?(Woods::Error)

  module Embedding
    # Orchestrates the indexing pipeline: reads extracted units, prepares text,
    # generates embeddings, and stores vectors. Supports full and incremental
    # modes with checkpoint-based resumability.
    #
    # When the vector store is an in-memory adapter (one that itself implements
    # +#each_entry+, not merely inherits the interface stub) and +output_dir+ is
    # set, a successful run — full or
    # incremental — persists the stores to disk via the Snapshotter pair and
    # atomically flips the +dumps/latest+ pointer. An incremental run hydrates
    # the store from the previous dump first, so the dump it writes is
    # cumulative. Persistent backends (pgvector, Qdrant) see zero behaviour
    # change — no Snapshotter is invoked.
    #
    # For that in-memory path the dump is the *only* durable copy of a vector,
    # which is why +checkpoint.json+ is written last, after the dump is
    # promoted. See the invariant note on {#process_units}.
    class Indexer # rubocop:disable Metrics/ClassLength
      # Raised when a unit's real identifier already matches the grammar
      # {#collect_embed_items} uses to generate ids for split units
      # ("identifier#chunk_N"). Five call sites elsewhere in the gem
      # (retrieval/, {Retriever}, {MCP::Bootstrapper}) strip
      # +/#chunk_\d+\z/+ unconditionally to recover a base identifier — so a
      # genuine unit named e.g. "Foo#chunk_0" (a controller action literally
      # named +chunk_0+) would be silently collapsed to "Foo" by those sites,
      # and {#prune_identifier} would then delete its vector as a superseded
      # chunk. The grammar is reserved rather than escaped: escaping would
      # require touching those five strip sites, several of which this task
      # is not permitted to change.
      class ChunkSuffixCollision < Woods::Error
        def initialize(identifier)
          super(
            "Unit identifier #{identifier.inspect} matches the embedding pipeline's " \
            'chunk-suffix grammar (/#chunk_\d+\z/), reserved for generated ids like ' \
            '"identifier#chunk_0". Rename the underlying unit (the file, method, or ' \
            'route that produced this identifier) so it does not end in "#chunk_<N>" ' \
            '— indexing cannot proceed safely otherwise, since retrieval strips that ' \
            'suffix unconditionally to recover the base identifier.'
          )
        end
      end

      # @param chunker [Chunking::SemanticChunker, nil] Splits oversize units
      #   into semantically coherent chunks before embedding. +nil+ disables
      #   chunking — units go to the provider whole (useful in tests).
      # @param checkpoint_interval [Integer] Save checkpoint every N batches (default: 10)
      # @param metadata_store [#each_entry, #bulk_load, nil] Optional metadata store.
      #   When present alongside an in-memory vector store, both are persisted
      #   at the end of a successful {#index_all} run.
      # @param resolved_config [Woods::ResolvedConfig, nil] Captured config for
      #   +woods.json+ — written to +output_dir+ on {#index_all} completion.
      # @param dump_retention_count [Integer] Number of completed dump directories
      #   to keep under +output_dir/dumps/+. Older dumps are removed after a
      #   successful {#index_all} run (default: 3).
      def initialize(provider:, text_preparer:, vector_store:, output_dir:, # rubocop:disable Metrics/ParameterLists
                     chunker: Chunking::SemanticChunker.new,
                     batch_size: 32, checkpoint_interval: 10,
                     metadata_store: nil,
                     resolved_config: nil,
                     dump_retention_count: 3)
        @provider = provider
        @text_preparer = text_preparer
        @vector_store = vector_store
        @output_dir = output_dir
        @chunker = chunker
        @batch_size = batch_size
        @checkpoint_interval = checkpoint_interval
        @metadata_store = metadata_store
        @resolved_config = resolved_config
        @dump_retention_count = dump_retention_count
        @persisted_ids = {}
        @durable_ids = nil
        @checkpoint_misses = 0
      end

      # Index all extracted units (full mode). Returns stats hash.
      #
      # When the vector store is an in-memory adapter, persists the embedded
      # vectors (and metadata, if a metadata store was provided) to disk under
      # +output_dir/dumps/<timestamp>/+ and atomically flips the +latest+
      # pointer. Writes +woods.json+ when +resolved_config+ was supplied.
      #
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_all
        process_units(load_units, incremental: false)
      end

      # Index only changed units (incremental mode). Returns stats hash.
      #
      # When the vector store is an in-memory adapter the run first hydrates it
      # from +dumps/latest+, so the dump written at the end of the run carries
      # both the previously embedded vectors and this run's new ones. See
      # {#process_units} for the invariant this upholds.
      #
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_incremental
        process_units(load_units, incremental: true)
      end

      private

      # Where this run's units are read from — the published generation's
      # payload, or the output root for a flat index.
      #
      # Globbing the output root would walk `payloads/` and ingest every
      # retained generation, so each unit would be embedded once per retained
      # payload. It also picks up `dumps/`, which holds no unit JSON but is
      # needlessly large to walk.
      #
      # @return [String]
      def units_dir
        Woods::Generation.new(output_dir: @output_dir).payload_dir.to_s
      end

      def load_units
        Dir.glob(File.join(units_dir, '**', '*.json')).filter_map do |path|
          next if File.basename(path) == 'checkpoint.json'

          # AtomicFile.read, not File.read: a bare read tags the bytes with the
          # process's default external encoding (US-ASCII under LANG=C), so a
          # single multibyte character in one unit raised EncodingError out of
          # JSON.parse and aborted the whole embed run.
          data = JSON.parse(AtomicFile.read(path))
          # Extraction output also contains index listings (_index.json arrays) and
          # summary files (manifest.json, dependency_graph.json, graph_analysis.json)
          # that live alongside per-unit JSON. Filter to the unit shape.
          data if data.is_a?(Hash) && data.key?('type') && data.key?('identifier')
        rescue JSON::ParserError, EncodingError => e
          warn "[woods] skipping unreadable unit file #{path} (#{e.class}: #{e.message})"
          nil
        end
      end

      # The invariant: **checkpoint.json never advances over a unit whose
      # vector was not durably stored.** Two things uphold it here.
      #
      # 1. Ordering. For a store whose only durable copy is the dump
      #    (+persistable?+), the checkpoint is written *after*
      #    {#persist_snapshot} has written +dumps/<ts>/+ and flipped the
      #    +latest+ pointer — and only then. A raise anywhere before that
      #    (provider error, ENOSPC, interrupted dump) leaves the checkpoint
      #    exactly where the previous run left it, so the next run re-embeds
      #    this run's work. The interval checkpoints are suppressed on that
      #    path for the same reason: a dump is a whole-store snapshot, so
      #    there is no partial durability for them to record, and recording
      #    it anyway is the #148 data loss in miniature. Durable backends
      #    (pgvector, Qdrant) keep the interval saves — for them each
      #    +store_batch+ *is* the durable write, so a mid-run crash really
      #    has persisted those batches.
      #
      # 2. Trust, verified. {#checkpoint_satisfied?} honours a checkpoint hit
      #    only when the durable artifact actually holds a vector for that
      #    unit. A checkpoint that ran ahead of its dump — an older gem with
      #    this bug, an interrupted promote, a store swap — self-heals into a
      #    re-embed instead of stranding the unit forever.
      def process_units(units, incremental:)
        prepare_run(incremental: incremental)
        checkpoint = incremental ? load_checkpoint : {}
        stats = { processed: 0, skipped: 0, errors: 0 }

        embed_batches(units, checkpoint, stats, incremental: incremental)

        report_checkpoint_misses
        vanished = incremental && persistable? ? drop_vanished_units : 0
        persist_snapshot if persistable? && snapshot_worth_writing?(stats, vanished, incremental: incremental)
        # Durable backends have no dump to rewrite, so staleness has to be
        # removed from the store itself — on full runs too, since a full run
        # against pgvector/Qdrant does not start from an empty store the way
        # the in-memory path does (#211).
        reconcile_durable_store if reconcilable?
        save_checkpoint(checkpoint)

        stats
      end

      # Is there anything new for a dump to capture?
      #
      # A dump is a whole-store snapshot, so writing one for a run that embedded
      # nothing rewrites and fsyncs every vector to produce byte-identical
      # content — and, worse, rotates the retention window, so three no-op
      # `woods:embed_incremental` runs evict every genuinely older dump in
      # favour of copies of the same state.
      #
      # Safe because nothing else mutates the *vector* store on a zero-processed
      # run: `prune_superseded_vectors` is reached only from `store_vectors`,
      # which runs only for items that were actually embedded. A checkpoint
      # self-heal counts as processed, so a run that re-embeds a stranded unit
      # still dumps.
      #
      # But "nothing embedded" is not "nothing changed" (B-069). `persist_snapshot`
      # writes the vector dump, the *metadata* dump and the config into one
      # directory and promotes them together, so skipping it also freezes
      # `metadata.msgpack`. A unit deleted from the index changes no unit's
      # `source_hash`, so `processed` stays 0 — and pre-#171 that left both the
      # stale vector *and* its metadata in place, which is what took the vector
      # from inert (no metadata, so `ContextAssembler#find_batch` missed it) to
      # retrievable by `codebase_retrieve`.
      #
      # Splitting the dump is not an option — a promoted directory holding fresh
      # metadata and no vectors would hydrate empty on the next run. So instead
      # the gate asks the fuller question: does the promoted dump describe units
      # the index no longer has? `@persisted_ids` is what the dump holds (the
      # hydration already read it, so this costs nothing) and
      # `@current_identifiers` is what this run saw. Anything in the first and
      # not the second is stale, and the dump has to be rewritten to drop it.
      #
      # Full runs always dump: they rebuild the store from scratch, so "nothing
      # processed" there means the store is genuinely empty and the dump must
      # say so rather than leave a stale one promoted.
      #
      # @return [Boolean]
      def snapshot_worth_writing?(stats, vanished, incremental:)
        return true unless incremental

        stats[:processed].positive? || vanished.positive?
      end

      # Fraction of the persisted units the vanished-unit sweep may remove
      # without an explicit override. Mirrors the 30% purge guard on the
      # gem's other destructive sweeps (Obsidian VaultExporter, Unblocked
      # Exporter — see their PURGE_GUARD_FRACTION).
      VANISHED_PRUNE_MAX_RATIO = 0.3
      private_constant :VANISHED_PRUNE_MAX_RATIO

      # Delete vectors the promoted dump holds for units the index no longer has.
      #
      # Detecting staleness is not enough on its own: `hydrate_persisted_vectors`
      # loads *every* vector in the dump back into the store, and
      # `prune_superseded_vectors` only touches identifiers that were embedded
      # this run — so without this the rewritten dump would faithfully reproduce
      # the stale vector it was rewritten to drop.
      #
      # `@persisted_ids` is what the dump holds (hydration already read it, so
      # this costs no IO) and `@current_identifiers` is what this run saw.
      # Pruning with an empty fresh-id list removes every chunk of the unit.
      #
      # Guarded by {#vanished_prune_permitted?} (B-079 / #191) — a refused
      # prune returns 0, which reads as "nothing vanished" to
      # {#snapshot_worth_writing?}, so a run that also embedded nothing writes
      # no dump and the retention window is not rotated over the good dumps.
      # The warn precedes the deletes: if the prune raises partway, the
      # operator still learns what it was doing.
      #
      # @return [Integer] how many units were dropped
      def drop_vanished_units
        return 0 if @persisted_ids.nil? || @persisted_ids.empty?

        vanished = @persisted_ids.keys.reject { |identifier| @current_identifiers.include?(identifier) }
        return 0 if vanished.empty?
        return 0 unless vanished_prune_permitted?(vanished)

        warn "[woods] dropping #{vanished.size} unit(s) from the vector index that the " \
             'extraction no longer holds; rewriting the dump.'
        vanished.each { |identifier| prune_identifier(identifier, []) }
        vanished.size
      end

      # Guard rail on the vanished-unit sweep (B-079 / #191).
      #
      # "Vanished" is computed as persisted-minus-current, so a run that
      # loaded *nothing* — a mismatched WOODS_OUTPUT between shells, deleted
      # extraction output, a glob failure — reads as "every unit vanished"
      # and would prune the whole store; with retention 3, two more such runs
      # then evict every dump that held real data. Two refusals, both
      # overridable with WOODS_ALLOW_PURGE=1:
      #
      # - nothing loaded at all while the dump holds vectors: almost
      #   certainly a wrong output dir, never a real mass deletion;
      # - vanished > {VANISHED_PRUNE_MAX_RATIO} of what the dump holds:
      #   suspicious enough to require an explicit override (or a full
      #   +woods:embed+, which rebuilds rather than prunes).
      #
      # Refusal never loses data: the stale vectors stay hydrated in the
      # store, so any dump this run does write (for freshly embedded work)
      # still carries them. Full runs never reach this guard —
      # +drop_vanished_units+ runs only on the incremental path, and a full
      # run's empty store is genuinely empty and must be dumped as such.
      #
      # @param vanished [Array<String>] identifiers about to be pruned
      # @return [Boolean] true when the prune may proceed
      def vanished_prune_permitted?(vanished)
        return true if purge_override?

        if @current_identifiers.empty?
          warn_empty_load_refusal
          return false
        end

        ratio = vanished.size.fdiv(@persisted_ids.size)
        return true if ratio <= VANISHED_PRUNE_MAX_RATIO

        warn "[woods] refusing to prune #{vanished.size} of #{@persisted_ids.size} persisted " \
             "vector unit(s) (#{(ratio * 100).round}% > #{(VANISHED_PRUNE_MAX_RATIO * 100).round}% " \
             'purge guard). If this mass deletion is intentional, set WOODS_ALLOW_PURGE=1 ' \
             'or run a full woods:embed.'
        false
      end

      def warn_empty_load_refusal
        warn "[woods] nothing loaded from #{@output_dir} — likely a wrong or empty output dir — " \
             "refusing to prune #{@persisted_ids.size} persisted vector unit(s) and leaving the " \
             'promoted dump untouched. Set WOODS_ALLOW_PURGE=1 to override.'
      end

      # @return [Boolean] true when WOODS_ALLOW_PURGE=1 bypasses the guard
      def purge_override?
        ENV.fetch('WOODS_ALLOW_PURGE', nil) == '1'
      end

      # Delete vectors a durable store holds for units the index no longer has.
      #
      # The dump-backed path gets staleness removal for free: the dump is
      # rewritten from the live store each run, so a dropped unit simply stops
      # being written. A durable backend has no such rewrite — rows in
      # `woods_vectors` and points in Qdrant survive until something deletes
      # them, which nothing did. A unit deleted from the codebase therefore
      # stayed retrievable through `codebase_retrieve` indefinitely, *including
      # after a full `woods:embed`*, because a full run against a durable store
      # does not begin from an empty store (#211).
      #
      # Runs on full and incremental alike, and reconciles against
      # `@current_identifiers` — every unit this run saw, embedded or skipped —
      # so a skipped-because-unchanged unit is never mistaken for a vanished one.
      #
      # Guarded by {#durable_prune_permitted?}, the same 30%-plus-empty-load
      # thresholds as the dump path (#191): the failure mode being defended
      # against is identical, and worse here, since a durable delete has no
      # dump to restore from.
      #
      # @return [Integer] how many units were dropped
      def reconcile_durable_store
        vanished = vanished_durable_identifiers
        return 0 if vanished.empty?
        return 0 unless durable_prune_permitted?(vanished)

        delete_durable_identifiers(vanished)
      end

      # Identifiers the durable store holds that this run did not see.
      #
      # Ids Woods could not have written are excluded rather than treated as
      # vanished (STO-2). A pgvector table or Qdrant collection may be shared
      # with another writer, and a foreign row can never appear in
      # +@current_identifiers+ — without this gate it would read as vanished
      # and be deleted on every single run. The adapter's own read side is the
      # first line of defence (Qdrant skips points with no +woods_identifier+
      # payload); this is the belt-and-braces one, keyed on shapes Woods never
      # mints as an identifier: canonical UUIDs and native integer point ids.
      #
      # @return [Array<String>]
      def vanished_durable_identifiers
        return [] if @durable_ids.nil?

        @durable_ids.keys.reject do |identifier|
          @current_identifiers.include?(identifier) || unattributable_id?(identifier)
        end
      end

      # Could Woods have written this id? Identifiers come from extraction —
      # class and file names — never a bare integer or a canonical UUID.
      #
      # @param identifier [Object] an id read back from the durable store
      # @return [Boolean]
      def unattributable_id?(identifier)
        identifier.is_a?(Integer) || Util::UUID5.uuid?(identifier)
      end

      # Delete every stored id belonging to the given identifiers.
      #
      # The warn precedes the deletes so an operator still learns what was
      # happening if one of them raises partway through.
      #
      # @param identifiers [Array<String>]
      # @return [Integer] how many units were dropped
      def delete_durable_identifiers(identifiers)
        stale_ids = identifiers.flat_map { |identifier| @durable_ids[identifier] }
        warn "[woods] deleting #{stale_ids.size} stale vector(s) for #{identifiers.size} unit(s) " \
             "from #{@vector_store.class} that the extraction no longer holds."
        stale_ids.each { |id| @vector_store.delete(id) }
        identifiers.each { |identifier| @durable_ids.delete(identifier) }
        identifiers.size
      end

      # Guard rail on the durable-store sweep. Mirrors
      # {#vanished_prune_permitted?}; the counts come from the store rather
      # than from a dump, and a refusal here leaves the stale vectors in place
      # (retrievable, but present) rather than risking a mass deletion that no
      # dump can undo.
      #
      # @param vanished [Array<String>] identifiers about to be deleted
      # @return [Boolean] true when the delete may proceed
      def durable_prune_permitted?(vanished)
        return true if purge_override?

        if @current_identifiers.empty?
          warn "[woods] nothing loaded from #{@output_dir} — likely a wrong or empty output dir — " \
               "refusing to delete #{@durable_ids.size} unit(s) from #{@vector_store.class}. " \
               'Set WOODS_ALLOW_PURGE=1 to override.'
          return false
        end

        ratio = vanished.size.fdiv(@durable_ids.size)
        return true if ratio <= VANISHED_PRUNE_MAX_RATIO

        warn "[woods] refusing to delete #{vanished.size} of #{@durable_ids.size} unit(s) from " \
             "#{@vector_store.class} (#{(ratio * 100).round}% > " \
             "#{(VANISHED_PRUNE_MAX_RATIO * 100).round}% purge guard). If this mass deletion is " \
             'intentional, set WOODS_ALLOW_PURGE=1.'
        false
      end

      # Per-run state. An Indexer instance may be reused across runs, and
      # neither the hydrated id index nor the miss counter may leak between
      # them.
      def prepare_run(incremental:)
        @persisted_ids = {}
        @current_identifiers = Set.new
        @durable_ids = nil
        @checkpoint_misses = 0
        hydrate_persisted_vectors if incremental && persistable?
        load_durable_store_ids if reconcilable?
      end

      # Read back what the durable store currently holds, as base identifiers.
      #
      # One enumeration serves both halves of #211:
      #
      # - {#checkpoint_satisfied?} can verify a checkpoint hit against the
      #   store instead of trusting it. Previously that verification existed
      #   only on the dump path, so switching `vector_store` from `:local` to
      #   pgvector/Qdrant left every unchanged unit stranded: the checkpoint
      #   said "done", the new store held nothing, and no run ever embedded it.
      # - {#reconcile_durable_store} can delete what extraction no longer has.
      #
      # Stored ids may carry a `#chunk_N` suffix; the map keeps every raw id
      # per base identifier so a delete can name each chunk exactly.
      def load_durable_store_ids
        @durable_ids = Hash.new { |hash, key| hash[key] = [] }
        @vector_store.each_id { |id| @durable_ids[base_identifier(id)] << id }
      rescue StandardError => e
        # A store that cannot be enumerated must not take the embed run down
        # with it. Reconciliation and the presence check both degrade to their
        # pre-#211 behaviour (skip, and trust the checkpoint).
        warn "[woods] could not read existing ids from #{@vector_store.class} " \
             "(#{e.class}: #{e.message}) — skipping durable-store reconciliation this run."
        @durable_ids = nil
      end

      # Strip the embedding-side chunk suffix to recover the unit identifier.
      # `collect_embed_items` writes "User#chunk_0" for chunked units; the
      # index only ever knows "User".
      #
      # A non-String id keeps its type: Qdrant's native integer point ids can
      # only have come from another writer, and stringifying them here would
      # disguise that shape from {#unattributable_id?}.
      def base_identifier(id)
        return id unless id.is_a?(String)

        id.sub(/#chunk_\d+\z/, '')
      end

      # Can this run reconcile the vector store against extraction output?
      #
      # True for durable adapters that genuinely implement +#each_id+ *and*
      # +#delete+ — as with {#persistable?}, +respond_to?+ is not the question,
      # since the interface defines both methods for every adapter as raising
      # stubs (B-108). Reconciliation ends in deletes, so an adapter that can
      # be enumerated but not deleted from must not enter the path at all
      # rather than raise +NotImplementedError+ mid-run (STO-11). The
      # dump-backed path is excluded: it already reconciles via
      # {#drop_vanished_units} plus the dump rewrite, and doing both would be
      # redundant work on the same store.
      def reconcilable?
        !persistable? &&
          implements_own?(@vector_store, :each_id) &&
          implements_own?(@vector_store, :delete)
      end

      def embed_batches(units, checkpoint, stats, incremental:)
        batch_count = 0
        units.each_slice(@batch_size) do |batch|
          process_batch(batch, checkpoint, stats, incremental: incremental)
          batch_count += 1
          save_checkpoint(checkpoint) if interval_checkpoints? && (batch_count % @checkpoint_interval).zero?
        end
      end

      # Never let a disagreement between checkpoint.json and the dump pass
      # silently — the re-embed is the safe outcome, but an operator seeing
      # unexpected embedding cost deserves to know why.
      def report_checkpoint_misses
        return if @checkpoint_misses.zero?

        warn "[woods] re-embedding #{@checkpoint_misses} unit(s) that checkpoint.json " \
             'marked as done but the vector store does not hold — the checkpoint had ' \
             'advanced past the durable artifact, or it describes a different store.'
      end

      # Interval checkpoints only make sense when each batch's +store_batch+
      # was itself durable. See the invariant note on {#process_units}.
      def interval_checkpoints?
        !persistable?
      end

      def process_batch(batch, checkpoint, stats, incremental:)
        to_embed = batch.each_with_object([]) do |unit_data, items|
          reject_chunk_suffix_collision!(unit_data['identifier'])

          # Every unit passes through here, embedded or skipped, so this is the
          # authoritative "what the index holds this run" set.
          @current_identifiers << unit_data['identifier']
          persist_unit_metadata(unit_data)
          if incremental && checkpoint_satisfied?(unit_data, checkpoint)
            stats[:skipped] += 1
            next
          end
          collect_embed_items(unit_data, items)
        end

        embed_and_store(to_embed, checkpoint, stats)
      end

      # May this unit's embedding be skipped?
      #
      # Incremental skip uses `source_hash`, which the extractor derives
      # from the unit's *source_code string only* (see ExtractedUnit#to_h
      # and Extractor#dump_units). It is NOT a hash of the serialized
      # unit_data JSON — so key ordering or whitespace in the _index.json
      # does not invalidate checkpoints across Ruby-minor upgrades.
      #
      # A matching hash is necessary but not sufficient: the vector must also
      # actually exist. On the dump-backed path that means present in what we
      # hydrated; on a durable backend, present in what the store reported.
      #
      # The durable half is #211's second bug. Before it, a checkpoint hit was
      # trusted outright on pgvector/Qdrant — so pointing `vector_store` at a
      # fresh durable store while keeping `output_dir` (the `:local` ->
      # `:postgresql` migration the docs recommend) stranded every unchanged
      # unit permanently: checkpoint.json said "embedded", the new store held
      # nothing, and no subsequent incremental run ever disagreed.
      def checkpoint_satisfied?(unit_data, checkpoint)
        return false unless checkpoint[unit_data['identifier']] == unit_data['source_hash']

        known_ids = persistable? ? @persisted_ids : @durable_ids
        # No durable view to check against (an adapter with no #each_id, or an
        # enumeration that failed) — fall back to trusting the checkpoint.
        return true if known_ids.nil?

        return true if known_ids.key?(unit_data['identifier'])

        @checkpoint_misses += 1
        false
      end

      # Persist a unit's metadata under its base identifier so retrieval can
      # resolve vector-search hits back to their unit data. Without this,
      # the metadata store is left empty at end of run — Snapshotter::Metadata
      # dumps a header with record_count: 0 and every MCP +codebase_retrieve+
      # call silently returns empty text, because ContextAssembler#find_batch
      # misses every candidate identifier. No-op when metadata_store is nil
      # (hosts that don't configure one). Stored under the base identifier,
      # not the chunk-suffixed id — chunks are an embedding-side concern only.
      def persist_unit_metadata(unit_data)
        return unless @metadata_store

        @metadata_store.store(unit_data['identifier'], unit_data)
      end

      # Refuse to index a unit whose real identifier already matches the
      # chunk-suffix grammar. See {ChunkSuffixCollision}. Checked ahead of
      # {#collect_embed_items} — an unchunked unit whose identifier already
      # ends in "#chunk_0" would sail through with +embed_id == identifier+
      # and never visibly generate the suffix itself, so the check can't
      # live downstream of chunking.
      def reject_chunk_suffix_collision!(identifier)
        return unless identifier.to_s.match?(CHUNK_SUFFIX_PATTERN)

        raise ChunkSuffixCollision, identifier
      end

      def collect_embed_items(unit_data, items)
        texts = prepare_texts(unit_data)
        identifier = unit_data['identifier']

        texts.each_with_index do |text, idx|
          embed_id = texts.length > 1 ? "#{identifier}#chunk_#{idx}" : identifier
          items << { id: embed_id, text: text, unit_data: unit_data,
                     source_hash: unit_data['source_hash'], identifier: identifier }
        end
      end

      def prepare_texts(unit_data) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        unit = build_unit(unit_data)
        apply_chunking(unit) if @chunker && unit.chunks.empty? && needs_chunking?(unit)
        # Extraction may have emitted chunks larger than the provider's
        # budget (rails_source in particular). Enforce the ceiling on
        # whatever chunks we have before handing off to the provider.
        @chunker&.enforce_chunk_limits!(unit) if unit.chunks.any?
        texts = unit.chunks.any? ? @text_preparer.prepare_chunks(unit) : [@text_preparer.prepare(unit)]
        # Drop empty/whitespace-only texts — embedding providers reject
        # them with 400 and retrying never succeeds. Unit is effectively
        # skipped when every text is empty (zero-source unit).
        texts.reject { |t| t.nil? || t.strip.empty? || content_portion_empty?(t, unit) }
      end

      # True when a prepared text is just the metadata prefix with no
      # underlying source content (empty source_code + empty chunks).
      # Avoids embedding prefix-only stubs that have no semantic value
      # and would poison the vector space with identical headers.
      def content_portion_empty?(text, unit)
        return false unless unit.chunks.empty?
        return false unless unit.source_code.nil? || unit.source_code.strip.empty?

        !text.nil?
      end

      # Does this unit exceed the embedding provider's single-input
      # budget? Returns false when the provider reports no budget, when
      # the TextPreparer has no calibrated chars-per-token ratio, or when
      # the unit's source fits.
      #
      # When the configured chunker carries a real tokenizer
      # (Embedding::TokenCounter) we also consult it — dense Ruby source
      # tokenizes hotter than chars/token averages suggest, and Ollama
      # rejects over-budget input outright (see ollama/ollama#14186).
      def needs_chunking?(unit)
        budget_tokens = safe_max_input_tokens
        return false if budget_tokens.nil?
        return false unless @text_preparer.respond_to?(:chars_per_token)

        source = unit.source_code || ''
        return true if chunker_token_oversize?(source)

        # Subtract a small prefix allowance — the TextPreparer adds a few
        # hundred characters of context header ([type] identifier / file /
        # dependencies) that count toward the budget too.
        char_budget = (budget_tokens * @text_preparer.chars_per_token).floor - PREFIX_CHAR_ALLOWANCE
        char_budget.positive? && source.length > char_budget
      end

      # Ask the chunker's real tokenizer whether +source+ already exceeds
      # the token budget. Returns false when the chunker wasn't built with
      # one (e.g., OpenAI path), leaving the char-based check in charge.
      def chunker_token_oversize?(source)
        return false unless @chunker&.token_counter && @chunker.max_tokens

        @chunker.token_counter.count(source) > @chunker.max_tokens
      end

      # Populate unit.chunks from the configured chunker. The chunker's
      # own +max_chars+ safety net is what guarantees each chunk fits,
      # so we pass the same char budget through here.
      def apply_chunking(unit)
        unit.chunks = @chunker.chunk(unit).map do |chunk|
          { content: chunk.content, chunk_type: chunk.chunk_type }
        end
      end

      def build_unit(data)
        unit = ExtractedUnit.new(type: data['type']&.to_sym, identifier: data['identifier'],
                                 file_path: data['file_path'])
        unit.namespace = data['namespace']
        unit.source_code = data['source_code']
        unit.dependencies = data['dependencies'] || []
        unit.chunks = (data['chunks'] || []).map { |c| c.transform_keys(&:to_sym) }
        unit
      end

      # Character budget reserved for the TextPreparer context prefix
      # ("[type] id / namespace / file / dependencies: …"). Typical
      # prefixes run ~200–400 chars; 512 gives room to spare.
      PREFIX_CHAR_ALLOWANCE = 512
      private_constant :PREFIX_CHAR_ALLOWANCE

      def embed_and_store(items, checkpoint, stats)
        return if items.empty?

        vectors = @provider.embed_batch(items.map { |i| i[:text] })
        store_vectors(items, vectors, checkpoint, stats)
      rescue StandardError => e
        stats[:errors] += items.size
        raise Woods::Error, "Embedding failed: #{e.message}"
      end

      def store_vectors(items, vectors, checkpoint, stats)
        entries = items.each_with_index.map do |item, idx|
          { id: item[:id], vector: vectors[idx],
            metadata: { type: item[:unit_data]['type'], identifier: item[:identifier],
                        file_path: item[:unit_data]['file_path'] } }
        end

        @vector_store.store_batch(entries)
        prune_superseded_vectors(items)
        prune_superseded_durable_vectors(items)

        items.each do |item|
          checkpoint[item[:identifier]] = item[:source_hash]
          stats[:processed] += 1
        end
      end

      # Suffix {#collect_embed_items} appends when a unit is split across
      # several vectors. Mirrors the pattern in {Retriever},
      # {Retrieval::ContextAssembler} and {MCP::Bootstrapper}.
      CHUNK_SUFFIX_PATTERN = /#chunk_\d+\z/
      private_constant :CHUNK_SUFFIX_PATTERN

      # Hydrate the in-memory vector store from +dumps/latest+ so the dump
      # this run writes is the previous dump *plus* this run's changes.
      #
      # Hydration is lossless with respect to what the artifact can hold: the
      # WVF1 format stores id + float blob only, so the empty per-entry
      # metadata a load produces is exactly what a dump round-trips to either
      # way (woods-mcp back-fills it from metadata.msgpack at boot — see
      # MCP::Bootstrapper.populate_vector_metadata).
      #
      # A failure to read the dump (corrupt file, dimension mismatch after a
      # model switch) is not fatal: an empty +@persisted_ids+ means no
      # checkpoint hit can be honoured, so every unit is re-embedded and the
      # dump this run writes is complete. That is a full re-embed's cost, which
      # is the documented remedy for both of those conditions anyway — so warn
      # and carry on rather than stranding the host with no way forward.
      def hydrate_persisted_vectors
        require_relative '../index_artifact'
        require_relative '../storage/snapshotter'

        loaded = Storage::Snapshotter::Vector.load_or_empty(
          IndexArtifact.new(@output_dir), resolved_config: @resolved_config
        )
        entries = loaded.each_entry.map { |id, vector, metadata| { id: id, vector: vector, metadata: metadata || {} } }
        @vector_store.clear! if @vector_store.respond_to?(:clear!)
        @vector_store.bulk_load(entries)
        @persisted_ids = index_ids_by_identifier(entries)
      rescue StandardError => e
        warn "[woods] could not hydrate vectors from the latest dump (#{e.class}: #{e.message}); " \
             're-embedding every unit so the dump this run writes is complete.'
        @vector_store.clear! if @vector_store.respond_to?(:clear!)
        @persisted_ids = {}
      end

      # base identifier => the vector ids the dump holds for it.
      def index_ids_by_identifier(entries)
        entries.each_with_object({}) do |entry, index|
          identifier = entry[:id].to_s.sub(CHUNK_SUFFIX_PATTERN, '')
          (index[identifier] ||= []) << entry[:id]
        end
      end

      # Drop vector ids the previous dump held for a re-embedded identifier
      # that this run did not rewrite. A unit that used to split into five
      # chunks and now splits into three would otherwise leave +#chunk_3+ and
      # +#chunk_4+ in the hydrated store, and the dump would serve chunks
      # whose source no longer exists.
      #
      # Scoped to the hydrated ids on purpose: a durable backend's own
      # staleness is its own write path's business, and this method must not
      # start issuing deletes against pgvector or Qdrant.
      def prune_superseded_vectors(items)
        return if @persisted_ids.empty?
        return unless implements_own?(@vector_store, :delete)

        items.group_by { |item| item[:identifier] }.each do |identifier, group|
          prune_identifier(identifier, group.map { |item| item[:id] })
        end
      end

      def prune_identifier(identifier, fresh_ids)
        previous = @persisted_ids[identifier]
        return unless previous

        (previous - fresh_ids).each { |id| @vector_store.delete(id) }
        @persisted_ids[identifier] = fresh_ids
      end

      # Durable stores do not get rewritten from a complete dump after each
      # run. If a still-present unit is re-embedded with fewer chunks, remove
      # the old chunk rows/points that no current embed item rewrote.
      def prune_superseded_durable_vectors(items)
        return if @durable_ids.nil?
        return unless implements_own?(@vector_store, :delete)

        items.group_by { |item| item[:identifier] }.each do |identifier, group|
          prune_durable_identifier(identifier, group.map { |item| item[:id] })
        end
      end

      def prune_durable_identifier(identifier, fresh_ids)
        previous = @durable_ids[identifier]
        return unless previous

        (previous - fresh_ids).each { |id| @vector_store.delete(id) }
        @durable_ids[identifier] = fresh_ids
      end

      # A checkpoint that cannot be parsed *or read* degrades to "no
      # checkpoint" — every unit reads as changed and is re-embedded, the same
      # self-healing outcome as a corrupt checkpoint. AtomicFile.read keeps a
      # non-ASCII identifier from raising EncodingError here in the first place.
      def load_checkpoint
        path = File.join(@output_dir, 'checkpoint.json')
        return {} unless File.exist?(path)

        checkpoint_hashes(JSON.parse(AtomicFile.read(path)))
      rescue JSON::ParserError, EncodingError
        {}
      end

      # AtomicFile.write, not File.write: a crash mid-write must leave the old
      # checkpoint intact, never a torn partial — a truncated checkpoint reads
      # as "no checkpoint" and silently re-embeds everything.
      def save_checkpoint(checkpoint)
        AtomicFile.write(File.join(@output_dir, 'checkpoint.json'), JSON.generate(checkpoint_payload(checkpoint)))
      end

      # Schema of the on-disk checkpoint payload when {#resolved_config} is
      # tracked. Bump only alongside a reader change in {#checkpoint_hashes}.
      CHECKPOINT_SCHEMA_VERSION = 1
      private_constant :CHECKPOINT_SCHEMA_VERSION

      # The provider/model/dimension triple checkpoint.json is stamped with,
      # or +nil+ when this indexer was built without a +resolved_config+ (no
      # identity to stamp or compare against — see {#checkpoint_payload} and
      # {#checkpoint_hashes}, both of which treat +nil+ as "skip identity
      # tracking entirely" for full backward compatibility with callers that
      # never pass one).
      #
      # Reads {ResolvedConfig#to_snapshot_json} rather than calling
      # +#embedding_provider+/+#dimension+ directly so a test double only
      # needs to stub the one method the WVF1 header path already requires.
      #
      # @return [Hash, nil]
      def current_checkpoint_identity
        return nil unless @resolved_config

        provider = @resolved_config.to_snapshot_json['embedding_provider'] || {}
        provider.transform_keys(&:to_s).slice('class', 'model', 'dimension')
      end

      # Wrap the flat identifier=>source_hash map with its identity stamp for
      # writing, or leave it flat when this run tracks no identity.
      def checkpoint_payload(checkpoint)
        identity = current_checkpoint_identity
        return checkpoint if identity.nil?

        { 'schema_version' => CHECKPOINT_SCHEMA_VERSION, 'identity' => identity, 'hashes' => checkpoint }
      end

      # Recover the flat identifier=>source_hash map {#checkpoint_satisfied?}
      # consumes from whichever on-disk shape was parsed. Two shapes:
      #
      # - versioned (carries a top-level "hashes" key): written by this gem
      #   version, stamped with the provider/model/dimension identity that
      #   produced it (see #checkpoint_payload). A stamped identity that
      #   disagrees with {#current_checkpoint_identity} — a same-dimension
      #   model switch, the P1 finding this exists to close — means nothing
      #   here can say which individual hits are still good, so the *whole*
      #   checkpoint is discarded rather than trusted per-unit.
      # - flat (every checkpoint written before this gem version): carries no
      #   identity at all. When this run tracks identity (a resolved_config
      #   was given), "no identity recorded" is indistinguishable from "the
      #   identity that produced this changed" — so it is discarded the same
      #   way: one full re-embed, after which every checkpoint this gem
      #   writes is stamped and can be trusted again. When this run has no
      #   resolved_config either there is nothing to compare against, and the
      #   flat map is trusted exactly as every prior gem version did.
      def checkpoint_hashes(data)
        return data unless data.is_a?(Hash)

        current = current_checkpoint_identity
        return checkpoint_hashes_versioned(data, current) if data.key?('hashes')
        return data if current.nil?

        warn '[woods] checkpoint.json predates embedding-identity tracking and cannot be ' \
             'verified against the current provider/model — discarding it and re-embedding ' \
             'every unit once so future checkpoints are stamped and can be trusted safely.'
        {}
      end

      def checkpoint_hashes_versioned(data, current)
        stamped = data['identity']
        return data['hashes'] || {} if current.nil? || stamped == current

        warn '[woods] checkpoint.json was stamped for a different embedding identity ' \
             "(#{stamped.inspect} vs current #{current.inspect}) — the provider or model " \
             'changed since the last run. Discarding the checkpoint and re-embedding every ' \
             'unit so no stale-model vector survives.'
        {}
      end

      # Returns true when the vector store can actually be dumped to
      # +output_dir+ — that is, when it genuinely implements the persistence
      # seam (+#each_entry+).
      #
      # +respond_to?+ is the wrong question, and asking it was a live crash.
      # {Storage::VectorStore::Interface} *defines* +#each_entry+ (as a
      # +NotImplementedError+ raise) and +#bulk_load+ (delegating to
      # +#store_batch+), and every adapter includes the module — so pgvector
      # and Qdrant answered +respond_to?(:each_entry)+ with +true+ despite
      # implementing neither. +persistable?+ said yes, and {#persist_snapshot}
      # drove +Snapshotter::Vector.dump+ into the interface's raise at the very
      # end of an otherwise-successful run, discarding a whole embed pass
      # (every vector already paid for) with a bare +NotImplementedError+.
      #
      # Ask who *owns* the method instead: an adapter that merely inherited the
      # interface's stub has not implemented it. +bulk_load+ is deliberately not
      # part of the test — its interface default is a working implementation, so
      # it discriminates nothing.
      def persistable?
        return false unless @output_dir

        implements_own?(@vector_store, :each_entry)
      end

      # @provider's input-token budget, or nil when it has none.
      # `respond_to?` alone is the wrong guard here: {Embedding::Provider::Interface}
      # *defines* +max_input_tokens+ as a +NotImplementedError+ stub, so a
      # provider that merely includes the interface without overriding it
      # still answers +respond_to?+ with +true+ (B-108) and raises when
      # called. A provider with no such method at all still needs the
      # +respond_to?+ guard to avoid a bare +NoMethodError+.
      #
      # @return [Integer, nil]
      def safe_max_input_tokens
        return nil unless @provider.respond_to?(:max_input_tokens)

        @provider.max_input_tokens
      rescue NotImplementedError
        nil
      end

      # Does +object+ define +method_name+ itself, rather than inheriting the
      # vector-store interface's default stub?
      #
      # @param object [Object] the adapter under test
      # @param method_name [Symbol]
      # @return [Boolean]
      def implements_own?(object, method_name)
        return false unless object.respond_to?(method_name)
        return true unless defined?(Storage::VectorStore::Interface)

        object.method(method_name).owner != Storage::VectorStore::Interface
      end

      # Persist stores to a timestamped dump directory, write +woods.json+,
      # flip the +latest+ pointer, then prune old dumps.
      def persist_snapshot
        require_relative '../index_artifact'
        require_relative '../storage/snapshotter'

        artifact = IndexArtifact.new(@output_dir)
        dump_dir = unique_dump_dir(artifact)

        # Pass resolved_config: the WVF1 header carries a model_name field, and
        # omitting it wrote an empty string into every dump — so the artifact
        # could not say which model produced it, and any check that wants to
        # compare a dump against the configured provider has nothing to read.
        Storage::Snapshotter::Vector.dump(@vector_store, artifact, dump_dir, resolved_config: @resolved_config)

        if @metadata_store.respond_to?(:each_entry) && @metadata_store.respond_to?(:bulk_load)
          Storage::Snapshotter::Metadata.dump(@metadata_store, artifact, dump_dir)
        end

        # Written INSIDE the dump directory, as part of the dump, so #promote
        # below is the single commit point for the vectors/metadata AND the
        # config that describes them — a crash between this write and
        # #promote leaves the previous promoted dump (and its own config)
        # untouched. See IndexArtifact#read_config, which prefers this copy.
        artifact.write_dump_config(dump_dir, @resolved_config) if @resolved_config

        artifact.promote(dump_dir)

        # Written AFTER promote so the commit point stays the promotion
        # above — this root copy is for anything that reads
        # output_dir/woods.json directly instead of through
        # IndexArtifact#read_config.
        artifact.write_config(@resolved_config) if @resolved_config

        prune_old_dumps(artifact)
      end

      # Seconds of timestamp to walk forward looking for a free dump directory
      # name before giving up and letting Errno::EEXIST out.
      DUMP_DIR_ATTEMPTS = 60
      private_constant :DUMP_DIR_ATTEMPTS

      # Mint a dump directory, stepping the timestamp forward on a collision.
      #
      # Dump directory names have one-second resolution and {IndexArtifact}
      # deliberately refuses to reuse one (an explicit +now:+ collision is a
      # caller error). Now that *every* run dumps — and incremental runs carry
      # no cooldown, unlike the full runs PipelineGuard rate-limits — two runs
      # inside one second is reachable on a small index. Walking the name
      # forward keeps chronological and lexicographic order in agreement
      # (…28Z < …29Z), which is what prune_old_dumps sorts on, and beats
      # discarding embedding work that has already been done and paid for.
      def unique_dump_dir(artifact)
        now = Time.now.utc
        attempts = 0
        begin
          artifact.new_dump_dir(now: now)
        rescue Errno::EEXIST
          attempts += 1
          raise if attempts >= DUMP_DIR_ATTEMPTS

          now += 1
          retry
        end
      end

      # Remove old dump directories beyond the retention window.
      #
      # Keeps the +@dump_retention_count+ most-recently-created directories
      # (sorted by name, which is a UTC timestamp so lexicographic order equals
      # chronological order). The current +latest+ directory is always kept —
      # true by construction: it is filtered out of the prune candidates
      # below, not merely assumed to sort last. A backward wall-clock step
      # (NTP correction, a stubbed clock in a spec) can mint a new dump
      # directory whose name sorts *before* older ones, which used to put the
      # dump #persist_snapshot had just promoted at the front of the "oldest
      # first" prune list — deleting it out from under the +latest+ pointer
      # that was made to point at it moments earlier.
      def prune_old_dumps(artifact)
        return if @dump_retention_count.nil? || @dump_retention_count <= 0

        dumps_root = artifact.dumps_root
        return unless dumps_root.exist?

        latest = artifact.latest_dump_path&.to_s
        dirs = sorted_dump_dirs(dumps_root)
        excess = dirs.length - @dump_retention_count
        return unless excess.positive?

        (dirs.first(excess) - [latest]).each { |dir| FileUtils.rm_rf(dir) }
      end

      def sorted_dump_dirs(dumps_root)
        dumps_root.children
                  .select(&:directory?)
                  .sort_by(&:basename)
                  .map(&:to_s)
      end
    end
  end
end
