# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pgvector generator template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/codebase_index/templates/add_pgvector_to_codebase_index.rb.erb', __dir__)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'enables pgvector extension' do
    content = File.read(template_path)
    expect(content).to include('enable_extension')
    expect(content).to include('vector')
  end

  it 'adds vector column to codebase_embeddings' do
    content = File.read(template_path)
    expect(content).to include('codebase_embeddings')
    expect(content).to include('embedding_vector')
  end

  it 'creates HNSW index' do
    content = File.read(template_path)
    expect(content).to match(/hnsw|ivfflat/i)
  end
end

RSpec.describe 'Pgvector generator class' do
  let(:generator_path) do
    File.expand_path('../../lib/generators/codebase_index/pgvector_generator.rb', __dir__)
  end

  it 'generator file exists' do
    expect(File.exist?(generator_path)).to be true
  end

  it 'defines PgvectorGenerator' do
    content = File.read(generator_path)
    expect(content).to include('class PgvectorGenerator')
  end
end
