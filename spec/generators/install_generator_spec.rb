# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods/version'

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
  # The template file has Unicode box-drawing characters in section headers
  # (── and em-dashes). Force UTF-8 so regex matches don't raise
  # "invalid byte sequence in US-ASCII" on environments where
  # Encoding.default_external is US-ASCII.
  let(:content) { File.read(template_path, encoding: 'UTF-8') }

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'template calls Woods.configure' do
    expect(content).to include('Woods.configure do |config|')
  end

  it 'template sets output_dir relative to Rails.root' do
    expect(content).to include('Rails.root.join')
    expect(content).to include('tmp/woods')
  end

  it 'template mentions configure_with_preset idiom' do
    expect(content).to include('configure_with_preset')
  end

  it 'template covers console_mcp options' do
    expect(content).to include('console_mcp_enabled')
    expect(content).to include('console_redacted_columns')
  end

  it 'template keeps console MCP disabled by default' do
    # The enable line must be commented out
    expect(content).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end

  it 'template mentions all three defense layers' do
    expect(content).to include('Layer 1')
    expect(content).to include('Layer 2')
    expect(content).to include('Layer 3')
  end

  # F8: TokenCounter is exact only with an injected, model-matched tokenizer;
  # nothing in the gem loads the `tokenizers` gem on its own.
  it 'does not promise exact token counts from installing the tokenizers gem' do
    expect(content).not_to match(/Install `gem "tokenizers"`/)
    expect(content).to include('estimates')
    expect(content).to include('Woods::Embedding::TokenCounter')
  end

  it 'has frozen_string_literal comment' do
    expect(content).to start_with('# frozen_string_literal: true')
  end
end

# The generator runs in a child process, as spec/generators/watch_generator_spec.rb
# does: loading a partial Rails constant in the default suite changes unrelated
# MCP runtime detection. The repository bundle carries railties but not Active
# Record, which is exactly the host the default install path must work on
# (#618); the legacy migration needs Active Record and runs under a Rails
# appraisal row (`WOODS_RUN_BOOTED_APP=1 BUNDLE_GEMFILE=gemfiles/rails_8.1.gemfile`).
RSpec.describe 'Install generator' do
  around do |example|
    Dir.mktmpdir('woods install generator ') do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  def generate(*arguments, behavior: 'invoke')
    repo = File.expand_path('../..', __dir__)
    gemfile = File.expand_path(ENV.fetch('BUNDLE_GEMFILE', 'Gemfile'), repo)
    environment = Bundler.unbundled_env.merge('BUNDLE_GEMFILE' => gemfile, 'BUNDLE_LOCKFILE' => "#{gemfile}.lock")
    script = <<~SCRIPT
      require 'bundler/setup'
      require 'generators/woods/install_generator'
      root, behavior = ARGV.shift(2)
      Woods::Generators::InstallGenerator.start(ARGV, destination_root: root, behavior: behavior.to_sym)
      puts "active_record_loaded=\#{defined?(ActiveRecord) ? 'yes' : 'no'}"
    SCRIPT
    Open3.capture3(environment, Gem.ruby, '-I', File.join(repo, 'lib'), '-e', script,
                   @root, behavior, *arguments, unsetenv_others: true)
  end

  def active_record_in_bundle?
    _, _, status = generate('--pretend', '--legacy-migration')
    status.success?
  end

  def written_files
    Dir.glob('**/*', base: @root).select { |path| File.file?(File.join(@root, path)) }.sort
  end

  it 'writes only the initializer by default, without loading Active Record' do
    stdout, stderr, status = generate

    expect(status.success?).to be(true), stderr
    expect(written_files).to eq(['config/initializers/woods.rb'])
    expect(stdout).to include('active_record_loaded=no')
    initializer = File.read(File.join(@root, 'config/initializers/woods.rb'), encoding: 'UTF-8')
    expect(initializer).to include('Woods.configure do |config|')
    expect(initializer).to include("blob/v#{Woods::VERSION}/docs/")
  end

  it 'leaves an identical initializer alone on a repeat run' do
    _, stderr, status = generate
    expect(status.success?).to be(true), stderr
    before = File.read(File.join(@root, 'config/initializers/woods.rb'), encoding: 'UTF-8')

    stdout, stderr, status = generate

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('identical')
    expect(File.read(File.join(@root, 'config/initializers/woods.rb'), encoding: 'UTF-8')).to eq(before)
    expect(written_files).to eq(['config/initializers/woods.rb'])
  end

  it 'writes nothing under --pretend' do
    stdout, stderr, status = generate('--pretend')

    expect(status.success?).to be(true), stderr
    expect(stdout).to include('config/initializers/woods.rb')
    expect(written_files).to be_empty
  end

  it 'refuses --legacy-migration before writing anything when Active Record is not available' do
    skip 'Active Record is in this bundle; the refusal needs a railties-only bundle' if active_record_in_bundle?

    _, stderr, status = generate('--legacy-migration')

    expect(status.success?).to be(false)
    expect(stderr).to include('--legacy-migration needs Active Record')
    expect(written_files).to be_empty
  end

  it 'writes the legacy migration once, and only on --legacy-migration', :booted_app do
    skip 'the legacy migration needs Active Record in the bundle' unless active_record_in_bundle?

    _, stderr, status = generate('--legacy-migration')
    expect(status.success?).to be(true), stderr

    migrations = Dir.glob('db/migrate/*_create_woods_tables.rb', base: @root)
    expect(migrations.size).to eq(1)
    migration = File.read(File.join(@root, migrations.first), encoding: 'UTF-8')
    expect(migration).to match(/class CreateWoodsTables < ActiveRecord::Migration\[\d+\.\d+\]/)
    expect(migration).to include('create_table :woods_units')

    _, stderr, status = generate('--legacy-migration')
    expect(status.success?).to be(true), stderr
    expect(Dir.glob('db/migrate/*_create_woods_tables.rb', base: @root).size).to eq(1)

    _, stderr, status = generate
    expect(status.success?).to be(true), stderr
    expect(written_files.grep(%r{\Adb/migrate/}).size).to eq(1)
  end
end
