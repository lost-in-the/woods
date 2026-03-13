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
end
