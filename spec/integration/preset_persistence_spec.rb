# frozen_string_literal: true

require 'json'
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

  %i[local shared_filesystem].each do |preset|
    it "persists, bootstraps, and retrieves through the #{preset} preset" do
      Dir.mktmpdir("woods-#{preset}-preset") do |dir|
        config = Woods::Builder.preset_config(preset)
        config.output_dir = dir
        config.embedding_provider = :fake
        config.embedding_options = { model: "#{preset}-fake", dimensions: 8 }

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
