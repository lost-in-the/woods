# frozen_string_literal: true

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Storage
    # Raised when a Snapshotter is applied to a persistent backend adapter
    # (e.g. pgvector, Qdrant, SQLite). Snapshotters only operate on in-memory
    # stores; persistent adapters manage their own durability.
    #
    # Named so that tests can assert it rather than catching a bare {Woods::Error}.
    class InapplicableBackend < Woods::Error; end
  end
end
