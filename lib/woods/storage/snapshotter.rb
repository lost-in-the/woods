# frozen_string_literal: true

require 'woods/storage/snapshotter/vector'
require 'woods/storage/snapshotter/metadata'

module Woods
  module Storage
    # Namespace for the Snapshotter pair that persists and hydrates in-memory
    # storage adapters to/from disk.
    #
    # Two adapters live here:
    # - {Snapshotter::Vector} — handles {VectorStore::InMemory} round-trips via
    #   a raw +pack("e*")+ binary format (+vectors.bin+ / +vectors.idx+).
    # - {Snapshotter::Metadata} — handles {MetadataStore::InMemory} round-trips
    #   via MessagePack (+metadata.msgpack+).
    #
    # Persistent backends (pgvector, Qdrant, SQLite) never touch the Snapshotter.
    # Passing one to {Snapshotter::Vector.dump} or {Snapshotter::Metadata.dump} raises
    # {InapplicableBackend} immediately — see each adapter's +validate_store!+.
    #
    # The two checks are deliberately different, because the two interfaces
    # are:
    # - {Snapshotter::Vector.validate_store!} checks *ownership* of
    #   +#each_entry+ rather than +respond_to?+ (B-108), because
    #   {VectorStore::Interface} defines it as a raising stub, so a durable
    #   adapter that merely includes the interface would otherwise pass.
    # - {Snapshotter::Metadata.validate_store!} can use plain +respond_to?+
    #   only because {MetadataStore::Interface} defines neither +#each_entry+
    #   nor +#bulk_load+ — the seams exist on +InMemory+ alone. Adding either
    #   stub to that interface would silently convert this check into the
    #   B-108 bug, so the ownership check must move with it (STO-12).
    #
    # {Woods::Embedding::Indexer#persist_snapshot} is the write-side caller,
    # invoked at the end of a successful {Woods::Embedding::Indexer#index_all}
    # or +#index_incremental+ run when the configured vector store is
    # in-memory. {Snapshotter::Vector.load_or_empty} is the read-side
    # counterpart, used both by an incremental run (to hydrate before
    # embedding) and by the MCP server at boot.
    module Snapshotter
    end
  end
end
