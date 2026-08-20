# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/builder'
require 'woods/index_artifact'
require 'woods/mcp/bootstrapper'
require 'woods/resolved_config'
require 'woods/storage/snapshotter'

RSpec.describe 'Preset persistence contracts' do
  around do |example|
    previous = Woods.configuration
    example.run
  ensure
    Woods.configuration = previous
  end

  it 'reopens local preset metadata from a clean Ruby process' do
    Dir.mktmpdir('woods-preset-persistence') do |dir|
      config = Woods::Builder.preset_config(:local)
      config.output_dir = dir
      store = Woods::Builder.new(config).build_metadata_store
      store.store('User', type: 'model', file_path: 'app/models/user.rb')

      database = File.join(dir, 'metadata.sqlite3')
      script = <<~RUBY
        require 'json'
        require 'woods'
        require 'woods/storage/metadata_store'

        store = Woods::Storage::MetadataStore::SQLite.new(database: ARGV.fetch(0))
        print JSON.generate(store.find('User'))
      RUBY

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        '-I', File.expand_path('../../lib', __dir__),
        '-e', script,
        database
      )

      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to include(
        'type' => 'model',
        'file_path' => 'app/models/user.rb'
      )
    end
  end

  {
    local: :in_memory,
    shared_filesystem: :in_memory,
    postgresql: :pgvector,
    production: :qdrant
  }.each do |preset, expected_adapter|
    it "persists, bootstraps, and retrieves through the #{preset} preset" do
      Dir.mktmpdir("woods-#{preset}-preset") do |dir|
        config = Woods::Builder.preset_config(preset)
        config.output_dir = dir
        config.embedding_provider = :fake
        config.embedding_options = { model: "#{preset}-fake", dimensions: 8 }

        durable_vector_store = Woods::Storage::VectorStore::InMemory.new
        case expected_adapter
        when :pgvector
          config.vector_store_options = { connection: Object.new }
          durable_vector_store.define_singleton_method(:ensure_schema!) { true }
          allow(Woods::Storage::VectorStore::Pgvector).to receive(:new).and_return(durable_vector_store)
        when :qdrant
          config.vector_store_options = { url: 'https://qdrant.example.test', collection: "woods_#{preset}" }
          durable_vector_store.define_singleton_method(:ensure_collection!) { |dimensions:| dimensions }
          allow(Woods::Storage::VectorStore::Qdrant).to receive(:new).and_return(durable_vector_store)
        end

        builder = Woods::Builder.new(config)
        provider = builder.build_embedding_provider
        vector_store = builder.build_vector_store(dimensions: provider.dimensions)
        metadata_store = builder.build_metadata_store

        vector_store.store('User', provider.embed('User model account'), type: 'model', identifier: 'User')
        metadata_store.store(
          'User',
          type: 'model', identifier: 'User', file_path: 'app/models/user.rb',
          source_code: 'class User < ApplicationRecord; end'
        )

        artifact = Woods::IndexArtifact.new(dir)
        resolved = Woods::ResolvedConfig.from_configuration(config, provider: provider)
        if config.vector_store == :in_memory || config.metadata_store == :in_memory
          dump_dir = artifact.new_dump_dir
          if config.vector_store == :in_memory
            Woods::Storage::Snapshotter::Vector.dump(vector_store, artifact, dump_dir, resolved_config: resolved)
          end
          if config.metadata_store == :in_memory
            Woods::Storage::Snapshotter::Metadata.dump(metadata_store, artifact, dump_dir, resolved_config: resolved)
          end
          artifact.promote(dump_dir)
        end
        artifact.write_config(resolved)

        Woods.configuration = config
        retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
        result = retriever.retrieve('User model')

        expect(state.status).to eq(:hydrated)
        expect(result.sources).not_to be_empty
        expect(result.context).to include('User')
        if expected_adapter == :pgvector
          expect(Woods::Storage::VectorStore::Pgvector).to have_received(:new)
            .with(connection: config.vector_store_options[:connection], dimensions: 8).at_least(:once)
        elsif expected_adapter == :qdrant
          expect(Woods::Storage::VectorStore::Qdrant).to have_received(:new)
            .with(hash_including(dimensions: 8)).at_least(:once)
        end
      end
    end
  end

  %i[postgresql production].each do |preset|
    it "names the #{preset} preset's missing OpenAI credential" do
      config = Woods::Builder.preset_config(preset)

      expect { Woods::Builder.new(config).build_embedding_provider }
        .to raise_error(Woods::ConfigurationError, /embedding_options\[:api_key\]/)
    end
  end

  it 'names the postgresql preset connection requirement' do
    config = Woods::Builder.preset_config(:postgresql)

    expect { Woods::Builder.new(config).build_vector_store(dimensions: 8) }
      .to raise_error(Woods::ConfigurationError, /vector_store_options\[:connection\]/)
  end

  it 'names the production preset Qdrant endpoint requirements' do
    config = Woods::Builder.preset_config(:production)

    expect { Woods::Builder.new(config).build_vector_store(dimensions: 8) }
      .to raise_error(Woods::ConfigurationError, /vector_store_options\[:url\].*\[:collection\]/)
  end
end
