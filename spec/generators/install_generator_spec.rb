# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'woods/db/migrator'

# Test the generator template output without Rails generators framework
RSpec.describe 'Install generator template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/woods/templates/create_woods_tables.rb.erb', __dir__)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'template contains CreateWoodsTables class' do
    content = File.read(template_path)
    expect(content).to include('class CreateWoodsTables')
  end

  it 'template creates woods_units table' do
    content = File.read(template_path)
    expect(content).to include('create_table :woods_units')
  end

  it 'template creates woods_edges table' do
    content = File.read(template_path)
    expect(content).to include('create_table :woods_edges')
  end

  it 'template creates woods_embeddings table' do
    content = File.read(template_path)
    expect(content).to include('create_table :woods_embeddings')
  end

  it 'template includes indexes' do
    content = File.read(template_path)
    expect(content).to include('add_index :woods_units')
    expect(content).to include('add_index :woods_edges')
  end
end

RSpec.describe 'Install generator initializer template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/woods/templates/woods.rb.tt', __dir__)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'template calls Woods.configure' do
    content = File.read(template_path)
    expect(content).to include('Woods.configure do |config|')
  end

  it 'template sets output_dir relative to Rails.root' do
    content = File.read(template_path)
    expect(content).to include('Rails.root.join')
    expect(content).to include('tmp/woods')
  end

  it 'template mentions configure_with_preset idiom' do
    content = File.read(template_path)
    expect(content).to include('configure_with_preset')
  end

  it 'template covers console_mcp options' do
    content = File.read(template_path)
    expect(content).to include('console_mcp_enabled')
    expect(content).to include('console_redacted_columns')
  end

  it 'template keeps console MCP disabled by default' do
    content = File.read(template_path)
    # The enable line must be commented out
    expect(content).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end

  it 'template mentions all three defense layers' do
    content = File.read(template_path)
    expect(content).to include('Layer 1')
    expect(content).to include('Layer 2')
    expect(content).to include('Layer 3')
  end

  it 'has frozen_string_literal comment' do
    content = File.read(template_path)
    expect(content).to start_with('# frozen_string_literal: true')
  end
end

RSpec.describe 'Install generator class' do
  let(:generator_path) do
    File.expand_path('../../lib/generators/woods/install_generator.rb', __dir__)
  end

  it 'generator file exists' do
    expect(File.exist?(generator_path)).to be true
  end

  it 'defines Woods::Generators::InstallGenerator' do
    content = File.read(generator_path)
    expect(content).to include('class InstallGenerator')
    expect(content).to include('module Generators')
  end

  it 'copies the initializer template' do
    content = File.read(generator_path)
    expect(content).to include("template 'woods.rb.tt'")
    expect(content).to include('config/initializers/woods.rb')
  end

  it 'copies the migration template' do
    content = File.read(generator_path)
    expect(content).to include('migration_template')
    expect(content).to include('create_woods_tables.rb.erb')
  end
end
