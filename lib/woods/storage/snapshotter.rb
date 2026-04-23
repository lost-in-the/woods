# frozen_string_literal: true

require 'woods/storage/snapshotter/vector'
require 'woods/storage/snapshotter/metadata'

module Woods
  module Storage
    # Namespace for the Snapshotter pair that persists and hydrates in-memory
    # storage adapters to/from disk.
    #
    # Two adapters live here:
    # - {Snapshotter::Vector} — handles {VectorStore::InMemory} round-trips via +pack("e*")+.
    # - {Snapshotter::Metadata} — handles {MetadataStore::InMemory} round-trips via MessagePack.
    #
    # Persistent backends (pgvector, Qdrant, SQLite) never touch the Snapshotter.
    # Passing one to {Snapshotter::Vector.dump} or {Snapshotter::Metadata.dump} raises
    # {InapplicableBackend} immediately.
    #
    # PR 2 ships stub implementations: +load_or_empty+ always returns an empty store
    # and +dump+ is a validated no-op. PR 3 wires in the real serialization paths.
    module Snapshotter
    end
  end
end
