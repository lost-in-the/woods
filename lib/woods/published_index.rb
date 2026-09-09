# frozen_string_literal: true

require 'digest'
require 'pathname'
require_relative 'generation'
require_relative 'payload_store'
require_relative 'mcp/index_reader'

module Woods
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
    def self.available_generations(index_dir)
      root = Pathname.new(index_dir.to_s)
      pointer = Woods::Generation.new(output_dir: root).current
      return [] if pointer.number.zero?

      payloads = Woods::PayloadStore.new(root)
      return [] unless payloads.root.directory?

      payloads.root.children.filter_map { |child| published_generation_number(child, pointer.number) }.sort
    end

    # A directory's generation number, when it qualifies as published: named
    # `gen-<N>` for N at or below +pointer+, holding a `manifest.json`.
    #
    # @param child [Pathname]
    # @param pointer [Integer] the currently published generation number
    # @return [Integer, nil]
    def self.published_generation_number(child, pointer)
      return nil unless child.directory?

      match = child.basename.to_s.match(/\Agen-(\d+)\z/)
      return nil unless match

      number = match[1].to_i
      return nil if number > pointer
      return nil unless child.join('manifest.json').file?

      number
    end
    private_class_method :published_generation_number

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
    def initialize(index_dir, generation: nil)
      @index_dir = Pathname.new(index_dir.to_s)
      @lock_file = nil
      @closed = false
      pointer = Woods::Generation.new(output_dir: @index_dir).current

      if pointer.number.zero? && generation.nil?
        initialize_flat_index
      else
        initialize_generation(generation || pointer.number)
      end

      @reader = Woods::MCP::IndexReader.new(@payload_dir.to_s, auto_refresh: false)
    end

    # @return [Integer] the generation being read; 0 for a flat index
    attr_reader :generation_number

    # @return [Pathname] the directory the units are read from
    attr_reader :payload_dir

    # Release the retention lock held on the pinned generation, if any.
    #
    # Safe to call more than once. A flat index (generation 0) holds no lock,
    # so this is a no-op for it.
    #
    # @return [void]
    def close
      return if @closed

      @lock_file&.flock(File::LOCK_UN)
      @lock_file&.close
      @lock_file = nil
      @closed = true
    end

    # @return [Hash] parsed manifest.json
    def manifest
      @reader.manifest
    end

    # @param identifier [String]
    # @return [Hash, nil] string-keyed unit, or nil
    def unit(identifier)
      @reader.find_unit(identifier)
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
      all_edges.select { |edge| wanted.nil? || edge[:via] == wanted }
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
        data = unit(entry['identifier'])
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
      file = File.open(@payload_dir.join('manifest.json').to_s, File::RDONLY) # rubocop:disable Style/FileOpen
      file.flock(File::LOCK_SH)
      @lock_file = file
    end

    # @return [Array<Hash>] normalized edges from the primary edge map plus variants
    def all_edges
      graph = @reader.raw_graph_data
      primary = (graph['edges'] || {}).flat_map { |from, list| Array(list).map { |raw| edge_hash(from, raw) } }
      primary + variant_edges(graph)
    end

    # Edges owned by a type recorded only in the graph's `variants` section:
    # an identifier that names units of more than one type keeps its other
    # types' out-edges there, since the primary `edges` map holds only one
    # type's edges per identifier.
    #
    # @param graph [Hash] raw dependency graph data
    # @return [Array<Hash>]
    def variant_edges(graph)
      variant_records(graph).flat_map do |record|
        Array(record['edges']).map { |raw| edge_hash(record['identifier'], raw) }
      end
    end

    # @param graph [Hash] raw dependency graph data
    # @return [Array<Hash>] entries from `variants` that name an identifier
    def variant_records(graph)
      Array(graph['variants']).select { |record| record.is_a?(Hash) && record['identifier'] }
    end

    # @param from [String]
    # @param raw [String, Hash] a bare target (pre-via graphs) or an edge hash
    # @return [Hash]
    def edge_hash(from, raw)
      if raw.is_a?(Hash)
        { from: from, to: raw['target'], via: raw['via'], through: raw['through'],
          disable_joins: raw['disable_joins'] == true }
      else
        { from: from, to: raw.to_s, via: nil, through: nil, disable_joins: false }
      end
    end
  end
end
