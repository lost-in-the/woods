# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require_relative 'generation'
require_relative 'payload_store'
require_relative 'mcp/index_reader'
require_relative 'published_index/edge_shaper'
require_relative 'published_index/generation_catalog'
require_relative 'published_index/typed_unit_reader'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  # A small, stable Ruby API over a published Woods index for tools that are
  # not MCP clients: RuboCop cops, CI gate scripts, `woods:check:*` tasks (#280).
  #
  # Three things it does that the MCP reader does not expose directly:
  #
  # * pin one published generation (the current one, or a retained older
  #   `payloads/gen-N`) for the reader's whole lifetime, so a check reads one
  #   consistent snapshot and can compare two generations against each other;
  # * hold that generation's {Woods::PayloadStore} retention lock for as long
  #   as the reader is open, so a concurrent publish's pruning cannot remove
  #   the payload out from under it;
  # * iterate edges with their attributes as plain hashes, and hand out a
  #   checksum keyed to the pinned payload for RuboCop's
  #   `external_dependency_checksum`.
  #
  # Everything is read-only and needs no Rails. Unit hashes are string-keyed,
  # exactly as written on disk. Unlike {Woods::MCP::IndexReader}, a
  # {PublishedIndex} never auto-refreshes: every fact it returns comes from
  # the one generation it opened with, for its entire lifetime.
  #
  # Holds an open file handle (a shared lock on the pinned generation's
  # `manifest.json`) for as long as the reader is open. Use the block form or
  # call {#close} explicitly; do not let an instance leak past the scope that
  # needs it.
  #
  # **Not thread-safe.** A single instance is meant for one script or cop
  # process reading one generation; it keeps no mutex around its lock file or
  # its underlying {Woods::MCP::IndexReader}. Give each thread its own
  # {PublishedIndex} rather than sharing one.
  #
  # @example A cop keyed on the index
  #   Woods::PublishedIndex.open(Rails.root.join('tmp/woods')) do |index|
  #     index.table_database_map            # => { "orders" => "primary", "events" => "analytics" }
  #     index.external_dependency_checksum  # => "9f2c..." (changes on every publish)
  #   end
  #
  # @example Comparing two generations
  #   before = Woods::PublishedIndex.new(dir, generation: 41)
  #   after  = Woods::PublishedIndex.new(dir, generation: 42)
  #   begin
  #     # ...
  #   ensure
  #     before.close
  #     after.close
  #   end
  #
  class PublishedIndex
    # Raised when `generation.json` exists but cannot be parsed. Distinct from
    # a *missing* pointer file, which means a flat (pre-2.0) index and is not
    # an error.
    class CorruptPointerError < Woods::Error; end

    # @return [Pathname] the index root passed to {#initialize}
    attr_reader :index_dir

    # Published generation numbers, ascending.
    #
    # A generation counts as published only when its number is at or below
    # the pointer `generation.json` currently names AND its payload directory
    # holds a `manifest.json`. A directory numbered above the pointer, or one
    # without a manifest (an interrupted or failed publish), is never listed.
    #
    # @param index_dir [String, Pathname]
    # @return [Array<Integer>]
    # @raise [CorruptPointerError] when `generation.json` exists but will not parse
    def self.available_generations(index_dir)
      GenerationCatalog.available(Pathname.new(index_dir.to_s))
    end

    # Open a reader, yield it, and guarantee the generation lock is released.
    #
    # Without a block this behaves exactly like {.new}: the caller owns the
    # lock and must call {#close}.
    #
    # @param (see #initialize)
    # @yieldparam index [PublishedIndex]
    # @return [PublishedIndex] when no block is given
    # @return [Object] the block's return value, when a block is given
    def self.open(index_dir, generation: nil)
      index = new(index_dir, generation: generation)
      return index unless block_given?

      begin
        yield index
      ensure
        index.close
      end
    end

    # @param index_dir [String, Pathname] the index root (holds generation.json)
    # @param generation [Integer, nil] pin a published generation; defaults to
    #   the currently published one
    # @raise [ArgumentError] when the index, or the requested generation, is
    #   not published
    # @raise [CorruptPointerError] when `generation.json` exists but will not parse
    def initialize(index_dir, generation: nil)
      @index_dir = Pathname.new(index_dir.to_s)
      @lock_file = nil
      pointer = GenerationCatalog.pointer(@index_dir)

      if pointer.number.zero? && generation.nil?
        initialize_flat_index
      else
        initialize_generation(generation || pointer.number)
      end

      open_reader!
    end

    # @return [Integer] the generation being read; 0 for a flat index
    # @return [Pathname] the directory the units are read from
    attr_reader :generation_number, :payload_dir

    # Release the retention lock held on the pinned generation, if any.
    #
    # Safe to call more than once. A flat index (generation 0) holds no lock,
    # so this is a no-op for it.
    #
    # @return [void]
    def close
      @lock_file&.flock(File::LOCK_UN)
      @lock_file&.close
      @lock_file = nil
    end

    # @return [Hash] parsed manifest.json
    def manifest
      @reader.manifest
    end

    # Look up one unit by identifier.
    #
    # `Woods::MCP::IndexReader#find_unit` (used when +type+ is nil) keys its
    # identifier map on identifier alone: if two type directories both list
    # the same identifier, whichever type sorts last in
    # `Woods::MCP::IndexReader::TYPE_DIRS` wins, silently. Pass +type+ to read
    # that type's unit file directly and skip the collision.
    #
    # @param identifier [String]
    # @param type [String, Symbol, nil] singular type name; disambiguates an
    #   identifier shared by more than one type
    # @return [Hash, nil] string-keyed unit, or nil
    def unit(identifier, type: nil)
      return @reader.find_unit(identifier) if type.nil?

      TypedUnitReader.call(@payload_dir, @reader, identifier, type.to_s)
    end

    # Index entries, each with a `'type'` key added.
    #
    # @param type [String, Symbol, nil] singular type name to restrict to
    # @return [Array<Hash>]
    def units(type: nil)
      dirs = if type
               dir = Woods::MCP::IndexReader::TYPE_TO_DIR[type.to_s]
               dir ? [dir] : []
             else
               Woods::MCP::IndexReader::TYPE_DIRS
             end
      dirs.flat_map do |dir|
        @reader.list_units(type: Woods::MCP::IndexReader::DIR_TO_TYPE[dir])
               .map { |entry| entry.merge('type' => Woods::MCP::IndexReader::DIR_TO_TYPE[dir]) }
      end
    end

    # Every forward edge in the graph, primary nodes and variants alike.
    #
    # An identifier shared by more than one type contributes one edge per
    # owning type; two edges are never folded into one just because they look
    # alike once reduced to `{from, to, via, through, disable_joins}`.
    #
    # @param via [String, Symbol, nil] restrict to one relationship label
    # @return [Array<Hash>] `{ from:, to:, via:, through:, disable_joins: }`
    def edges(via: nil)
      wanted = via&.to_s
      EdgeShaper.call(@reader.raw_graph_data).select { |edge| wanted.nil? || edge[:via] == wanted }
    end

    # @yieldparam edge [Hash] see {#edges}
    # @return [void]
    def each_edge(via: nil, &block)
      edges(via: via).each(&block)
    end

    # @param identifier [String]
    # @param via [String, Symbol, nil]
    # @return [Array<String>] identifiers that depend on `identifier`
    def dependents_of(identifier, via: nil)
      return Array((@reader.raw_graph_data['reverse'] || {})[identifier]).dup if via.nil?

      edges(via: via).select { |edge| edge[:to] == identifier }.map { |edge| edge[:from] }.uniq
    end

    # table name => database name, from model units that carry
    # `metadata.database` (Rails 6.1+ extractions).
    #
    # Reads every model unit once; cache it in a cop.
    #
    # @return [Hash{String => String}]
    def table_database_map
      units(type: 'model').each_with_object({}) do |entry, map|
        data = unit(entry['identifier'], type: 'model')
        next unless data

        table = data.dig('metadata', 'table_name')
        database = data.dig('metadata', 'database')
        map[table] = database if table && database
      end
    end

    # A digest of the pinned payload's `manifest.json`. RuboCop re-runs a cop
    # on every file when this value changes, so keying on the manifest that
    # was rewritten by the publish this reader is pinned to catches every
    # publish, whether the reader ended up on a flat index or a numbered
    # generation.
    #
    # @return [String] SHA-256 hex
    def external_dependency_checksum
      Digest::SHA256.file(@payload_dir.join('manifest.json').to_s).hexdigest
    end

    private

    # @return [void]
    def initialize_flat_index
      raise ArgumentError, "No manifest.json found in: #{@index_dir}" unless @index_dir.join('manifest.json').file?

      @generation_number = 0
      @payload_dir = @index_dir
    end

    # @param number [Integer]
    # @return [void]
    # @raise [ArgumentError] when +number+ is not a published generation
    def initialize_generation(number)
      dir = Woods::PayloadStore.new(@index_dir).path_for(number)
      unless self.class.available_generations(@index_dir).include?(number)
        raise ArgumentError, "Generation #{number} is not published under #{@index_dir} (expected #{dir.basename})"
      end

      @generation_number = number
      @payload_dir = dir
      acquire_retention_lock!
    end

    # Hold the same shared advisory lock on the generation's `manifest.json`
    # that {Woods::MCP::IndexReader} takes to survive concurrent retention
    # (see `PayloadStore#prune`'s doc comment on the lock protocol), but for
    # the whole lifetime of this reader rather than one pinned read. Kept
    # open until {#close}.
    #
    # @return [void]
    def acquire_retention_lock!
      @lock_file = File.open(@payload_dir.join('manifest.json').to_s, File::RDONLY)
      @lock_file.flock(File::LOCK_SH)
    end

    # Build the underlying reader, releasing any retention lock already
    # acquired ({#initialize_generation}) before letting the failure
    # propagate. Without this a `PublishedIndex` that fails to finish
    # constructing would leak an open advisory lock for the life of the
    # process.
    #
    # @return [void]
    def open_reader!
      @reader = Woods::MCP::IndexReader.new(@payload_dir.to_s, auto_refresh: false)
    rescue Exception # rubocop:disable Lint/RescueException -- release the lock for every failure mode, then re-raise unchanged
      close
      raise
    end
  end
end
