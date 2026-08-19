# frozen_string_literal: true

require 'spec_helper'
require 'erb'
require 'woods/storage/vector_store'
require 'woods/storage/pgvector'

RSpec.describe 'Pgvector generator template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/woods/templates/add_pgvector_to_woods.rb.erb', __dir__)
  end
  # Force UTF-8 like install_generator_spec does, so regex matches don't
  # raise "invalid byte sequence in US-ASCII" where the process default
  # external encoding is US-ASCII (plain Docker images, LANG=C).
  let(:content) { File.read(template_path, encoding: 'UTF-8') }

  # Render the template the way the generator does: @dimensions is the
  # generator's --dimensions option (default 1536).
  def render(dimensions = nil)
    migration = Class.new do
      def self.current_version
        '8.1'
      end
    end
    stub_const('ActiveRecord::Migration', migration)
    @dimensions = dimensions
    ERB.new(File.read(template_path, encoding: 'UTF-8')).result(binding)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'enables the pgvector extension' do
    expect(content).to include("enable_extension 'vector'")
  end

  it 'creates the woods_vectors table the Pgvector adapter reads and writes (#187)' do
    expect(content).to include("CREATE TABLE IF NOT EXISTS #{Woods::Storage::VectorStore::Pgvector::TABLE}")
  end

  it 'does not create the dead embedding_vector column on woods_embeddings (#187 regression)' do
    expect(content).not_to include('embedding_vector')
    expect(content).not_to include('woods_embeddings')
  end

  it 'declares an id column as the primary key' do
    expect(content).to match(/id TEXT PRIMARY KEY/)
  end

  it 'declares a JSONB metadata column' do
    expect(content).to match(/metadata JSONB/)
  end

  it 'creates an HNSW index matching the adapter index name' do
    expect(content).to include('USING hnsw')
    expect(content).to include('vector_cosine_ops')
    expect(content).to include("idx_#{Woods::Storage::VectorStore::Pgvector::TABLE}_embedding_hnsw")
  end

  it 'uses idempotent DDL so it coexists with the adapter ensure_schema!' do
    expect(content).to include('CREATE TABLE IF NOT EXISTS')
    expect(content).to include('CREATE INDEX IF NOT EXISTS')
  end

  it 'is reversible' do
    expect(content).to match(/def down\b/)
    expect(content).to include('drop_table :woods_vectors')
  end

  it 'renders the default vector dimensions when no option is given' do
    expect(render).to include('vector(1536)')
  end

  it 'renders the vector column with the --dimensions option' do
    expect(render(3072)).to include('vector(3072)')
  end
end

RSpec.describe 'Pgvector generator class' do
  let(:generator_path) do
    File.expand_path('../../lib/generators/woods/pgvector_generator.rb', __dir__)
  end
  let(:content) { File.read(generator_path, encoding: 'UTF-8') }

  it 'generator file exists' do
    expect(File.exist?(generator_path)).to be true
  end

  it 'defines PgvectorGenerator' do
    expect(content).to include('class PgvectorGenerator')
  end

  it 'exposes a dimensions option defaulting to 1536' do
    expect(content).to include('class_option :dimensions')
    expect(content).to include('default: 1536')
  end

  it 'describes the woods_vectors table, not woods_embeddings' do
    expect(content).to include('woods_vectors')
    expect(content).not_to include('woods_embeddings')
  end
end
