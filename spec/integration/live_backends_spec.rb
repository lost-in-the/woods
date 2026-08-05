# frozen_string_literal: true

# Storage-adapter contract specs against REAL backends (#220 / B-107).
#
# Every other storage spec drives the adapters through doubles. That is fast and
# it verifies the SQL/HTTP the adapter *builds*, but it cannot verify what the
# server does with it — which is how #181 shipped: `store_batch` built a
# perfectly well-formed multi-row `INSERT ... ON CONFLICT`, and PostgreSQL
# rejected it at execution time with `PG::CardinalityViolation` whenever one
# batch carried the same id twice. No double could have failed.
#
# Excluded from the default suite (see spec_helper's :live_backends filter).
# Opt in with WOODS_RUN_LIVE_BACKENDS=1 and running services:
#
#   WOODS_PG_URL=postgres://postgres:postgres@localhost:5432/woods_test
#   WOODS_QDRANT_URL=http://localhost:6333
#
# CI runs this in the `live-backends` job with pgvector/pgvector:pg16 and
# qdrant/qdrant service containers.

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'net/http'
require 'uri'
require 'woods/embedding/fake'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/storage/vector_store'
require 'woods/storage/pgvector'
require 'woods/storage/qdrant'

# Also tagged :integration so IntegrationHelpers (build_extracted_unit) is
# included — see spec/support/integration_helpers.rb.
RSpec.describe 'Live storage backends', :live_backends, :integration do
  # A deterministic, obviously-synthetic vector. Dimensions are tiny because
  # these specs assert on ordering and persistence, not embedding quality.
  def vec(*components)
    components.map(&:to_f)
  end

  # Drop and recreate the vectors table. A plain TRUNCATE is not enough: the
  # pgvector column's dimensionality is fixed at CREATE TABLE, so a context
  # using a different width would inherit the previous context's column and
  # fail with `expected N dimensions`.
  def reset_pg_schema!(connection, store)
    connection.execute("DROP TABLE IF EXISTS #{Woods::Storage::VectorStore::Pgvector::TABLE}")
    store.ensure_schema!
  end

  # Delete and recreate the collection. `delete_by_filter({})` builds an empty
  # Qdrant filter, which matches nothing rather than everything — so relying on
  # it to clear state leaks points between examples.
  def reset_qdrant_collection!(url, collection, dimensions, store)
    uri = URI.parse("#{url}/collections/#{collection}")
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(Net::HTTP::Delete.new(uri.request_uri)) }
    store.ensure_collection!(dimensions: dimensions)
  end

  describe 'pgvector against a real PostgreSQL' do
    let(:connection) do
      require 'active_record'
      # establish_connection is idempotent and lazy — it configures the pool
      # rather than dialing out, so calling it per example costs nothing and
      # keeps this out of a before(:all) hook.
      ActiveRecord::Base.establish_connection(
        ENV.fetch('WOODS_PG_URL', 'postgres://postgres:postgres@localhost:5432/woods_test')
      )
      ActiveRecord::Base.connection
    end
    let(:store) { Woods::Storage::VectorStore::Pgvector.new(connection: connection, dimensions: 3) }

    before { reset_pg_schema!(connection, store) }

    it 'creates its schema idempotently' do
      expect { store.ensure_schema! }.not_to raise_error
      expect(store.count).to eq(0)
    end

    it 'round-trips a stored vector through search' do
      store.store('User', vec(1, 0, 0), { type: 'model', file_path: 'app/models/user.rb' })

      results = store.search(vec(1, 0, 0), limit: 5)

      expect(results.map(&:id)).to eq(['User'])
      expect(results.first.metadata).to include('type' => 'model')
      expect(results.first.score).to be_within(0.001).of(1.0)
    end

    # The #181 regression. A duplicate id inside ONE batch made PostgreSQL raise
    # `cannot affect row a second time`; the adapter now collapses duplicates to
    # the last occurrence before building the statement.
    it 'accepts a batch containing a duplicate id, keeping the last occurrence (#181)' do
      entries = [
        { id: 'User', vector: vec(1, 0, 0), metadata: { revision: 'first' } },
        { id: 'Post', vector: vec(0, 1, 0), metadata: { revision: 'only' } },
        { id: 'User', vector: vec(0, 0, 1), metadata: { revision: 'second' } }
      ]

      expect { store.store_batch(entries) }.not_to raise_error
      expect(store.count).to eq(2)

      user = store.search(vec(0, 0, 1), limit: 1, filters: { revision: 'second' }).first
      expect(user.id).to eq('User')
    end

    it 'filters searches on metadata, including Array membership' do
      store.store_batch(
        [
          { id: 'User', vector: vec(1, 0, 0), metadata: { type: 'model' } },
          { id: 'UsersController', vector: vec(0.9, 0.1, 0), metadata: { type: 'controller' } },
          { id: 'UserMailer', vector: vec(0.8, 0.2, 0), metadata: { type: 'mailer' } }
        ]
      )

      scalar = store.search(vec(1, 0, 0), limit: 10, filters: { type: 'model' })
      expect(scalar.map(&:id)).to eq(['User'])

      membership = store.search(vec(1, 0, 0), limit: 10, filters: { type: %w[model mailer] })
      expect(membership.map(&:id)).to contain_exactly('User', 'UserMailer')
    end

    it 'deletes by id and by filter' do
      store.store_batch(
        [
          { id: 'User', vector: vec(1, 0, 0), metadata: { type: 'model' } },
          { id: 'Post', vector: vec(0, 1, 0), metadata: { type: 'model' } },
          { id: 'UsersController', vector: vec(0, 0, 1), metadata: { type: 'controller' } }
        ]
      )

      store.delete('User')
      expect(store.count).to eq(2)

      store.delete_by_filter(type: 'model')
      expect(store.count).to eq(1)
      expect(store.search(vec(0, 0, 1), limit: 5).map(&:id)).to eq(['UsersController'])
    end

    it 'rejects a wrong-dimension vector before writing anything' do
      expect do
        store.store_batch(
          [
            { id: 'Good', vector: vec(1, 0, 0), metadata: {} },
            { id: 'Bad', vector: vec(1, 0), metadata: {} }
          ]
        )
      end.to raise_error(Woods::Error, /Vector dimension mismatch/)

      expect(store.count).to eq(0)
    end
  end

  describe 'Qdrant against a real server' do
    let(:qdrant_url) { ENV.fetch('WOODS_QDRANT_URL', 'http://localhost:6333') }
    let(:collection) { "woods_live_#{ENV.fetch('GITHUB_RUN_ID', 'local')}" }
    let(:store) do
      Woods::Storage::VectorStore::Qdrant.new(
        url: qdrant_url,
        collection: collection,
        dimensions: 3,
        # The CI service and a local docker run are both loopback/private; the
        # SSRF guard is doing its job by default, so the spec opts out explicitly.
        allow_private_hosts: true
      )
    end

    before { reset_qdrant_collection!(qdrant_url, collection, 3, store) }

    it 'round-trips a stored vector, reverse-mapping the point id to the Woods identifier' do
      store.store('Billing::Payment', vec(1, 0, 0), { type: 'model' })

      results = store.search(vec(1, 0, 0), limit: 5)

      # The point id on the wire is a UUIDv5, but the adapter must hand back the
      # Woods identifier so it stays interchangeable with pgvector downstream.
      expect(results.map(&:id)).to eq(['Billing::Payment'])
      expect(results.first.metadata).to include('type' => 'model')
    end

    it 'stores a batch and counts it exactly' do
      store.store_batch(
        [
          { id: 'User', vector: vec(1, 0, 0), metadata: { type: 'model' } },
          { id: 'Post', vector: vec(0, 1, 0), metadata: { type: 'model' } }
        ]
      )

      expect(store.count).to eq(2)
    end

    it 'filters searches on metadata, including Array membership' do
      store.store_batch(
        [
          { id: 'User', vector: vec(1, 0, 0), metadata: { type: 'model' } },
          { id: 'UsersController', vector: vec(0.9, 0.1, 0), metadata: { type: 'controller' } },
          { id: 'UserMailer', vector: vec(0.8, 0.2, 0), metadata: { type: 'mailer' } }
        ]
      )

      scalar = store.search(vec(1, 0, 0), limit: 10, filters: { type: 'model' })
      expect(scalar.map(&:id)).to eq(['User'])

      membership = store.search(vec(1, 0, 0), limit: 10, filters: { type: %w[model mailer] })
      expect(membership.map(&:id)).to contain_exactly('User', 'UserMailer')
    end

    # A delete addressed by the raw Woods string would 400 or match nothing and
    # leave the vector live — silent data retention. This is the assertion that
    # keeps `.point_id` on the delete path.
    it 'deletes by Woods identifier, translating through the UUIDv5 point id' do
      store.store_batch(
        [
          { id: 'Billing::Payment', vector: vec(1, 0, 0), metadata: { type: 'model' } },
          { id: 'Post', vector: vec(0, 1, 0), metadata: { type: 'model' } }
        ]
      )

      store.delete('Billing::Payment')

      expect(store.count).to eq(1)
      expect(store.search(vec(1, 0, 0), limit: 5).map(&:id)).to eq(['Post'])
    end
  end

  # The whole embed pipeline, offline, against a real durable backend. The
  # `:fake` provider (#178) makes this possible without an API key or an Ollama
  # server: it is deterministic, so the same source text always embeds to the
  # same vector and a retrieval assertion is stable.
  describe 'offline embed -> retrieve round trip' do
    let(:dims) { 64 }
    let(:provider) { Woods::Embedding::Provider::Fake.new(dims: dims) }
    let(:preparer) { Woods::Embedding::TextPreparer.new(max_tokens: 8192) }
    let(:output_dir) { Dir.mktmpdir('woods-live-embed') }
    let(:connection) do
      require 'active_record'
      ActiveRecord::Base.establish_connection(
        ENV.fetch('WOODS_PG_URL', 'postgres://postgres:postgres@localhost:5432/woods_test')
      )
      ActiveRecord::Base.connection
    end
    let(:vector_store) do
      Woods::Storage::VectorStore::Pgvector.new(connection: connection, dimensions: dims)
    end

    let(:unit_hashes) do
      [
        {
          'type' => 'model', 'identifier' => 'User', 'file_path' => 'app/models/user.rb',
          'source_code' => "class User < ApplicationRecord\n  has_many :posts\nend\n"
        },
        {
          'type' => 'model', 'identifier' => 'Post', 'file_path' => 'app/models/post.rb',
          'source_code' => "class Post < ApplicationRecord\n  belongs_to :user\nend\n"
        },
        {
          'type' => 'controller', 'identifier' => 'UsersController',
          'file_path' => 'app/controllers/users_controller.rb',
          'source_code' => "class UsersController < ApplicationController\n  def index; end\nend\n"
        }
      ]
    end

    before do
      reset_pg_schema!(connection, vector_store)

      unit_hashes.each do |unit_hash|
        type_dir = File.join(output_dir, "#{unit_hash['type']}s")
        FileUtils.mkdir_p(type_dir)
        File.write(File.join(type_dir, "#{unit_hash['identifier']}.json"), JSON.generate(unit_hash))
      end
    end

    after { FileUtils.rm_rf(output_dir) }

    def build_indexer
      Woods::Embedding::Indexer.new(
        provider: provider,
        text_preparer: preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        batch_size: 2
      )
    end

    it 'embeds every unit into PostgreSQL and retrieves one by its own vector' do
      stats = build_indexer.index_all

      expect(stats[:errors]).to eq(0)
      expect(stats[:processed]).to eq(unit_hashes.size)
      expect(vector_store.count).to eq(unit_hashes.size)

      # Re-embedding the exact text a unit was indexed from must rank that unit
      # first — the end-to-end assertion that text, vector, and metadata all
      # survived the trip through a real server intact.
      user = unit_hashes.first
      query = preparer.prepare(build_extracted_unit(user))
      results = vector_store.search(provider.embed(query), limit: 3)

      expect(results.first.id).to eq('User')
      expect(results.first.metadata).to include('type' => 'model')
    end

    it 'skips unchanged units on a second incremental pass' do
      build_indexer.index_all
      count_after_full = vector_store.count

      stats = build_indexer.index_incremental

      expect(stats[:processed]).to eq(0)
      expect(stats[:skipped]).to eq(unit_hashes.size)
      expect(vector_store.count).to eq(count_after_full)
    end
  end
end
