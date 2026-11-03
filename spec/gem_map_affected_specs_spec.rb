# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/gem_mapper'
require 'woods/gem_map_affected_specs'
require 'woods/published_index'

# The self-map answers "which specs does this change reach?" (#926): spec
# files are mapped by the constants they name and the library files they
# require, and a change walks the reverse edges out to them.
RSpec.describe Woods::GemMapAffectedSpecs do
  around do |example|
    Dir.mktmpdir('woods-affected-specs') do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  def write(path, source)
    FileUtils.mkdir_p(@root.join(path).dirname)
    File.write(@root.join(path), source)
  end

  def affected(*paths)
    output = @root.join('map')
    Woods::GemMapper.new(root: @root, output_dir: output).map!
    described_class.new(Woods::PublishedIndex.open(output.to_s)).for(paths).fetch(:specs)
  end

  before do
    write('lib/woods.rb', "module Woods\n  def self.configure; end\nend\n")
    write('lib/woods/store.rb', "module Woods\n  class Store; end\nend\n")
    write('lib/woods/runner.rb', "module Woods\n  class Runner\n    def run\n      Store.new\n    end\n  end\nend\n")
    write('lib/woods/other.rb', "module Woods\n  class Other; end\nend\n")
    write('spec/store_spec.rb', "RSpec.describe Woods::Store do\nend\n")
    write('spec/runner_spec.rb', "RSpec.describe Woods::Runner do\nend\n")
    write('spec/other_spec.rb', "require 'woods/other'\nRSpec.describe 'other' do\nend\n")
    write('spec/configure_spec.rb', "RSpec.describe 'configure' do\n  it { Woods.configure }\nend\n")
  end

  it 'reaches the specs naming a changed constant and those naming its dependents' do
    expect(affected('lib/woods/store.rb')).to eq(%w[spec/runner_spec.rb spec/store_spec.rb])
  end

  it 'reaches a spec through the library file it requires' do
    expect(affected('lib/woods/other.rb')).to eq(%w[spec/other_spec.rb])
  end

  it 'reaches a spec that reads every library file from a change to any of them' do
    write('spec/tree_spec.rb', "Dir[File.expand_path('../lib/woods/**/*.rb', __dir__)].each { |path| path }\n")

    expect(affected('lib/woods/other.rb')).to eq(%w[spec/other_spec.rb spec/tree_spec.rb])
  end

  it 'includes a changed spec itself' do
    expect(affected('spec/store_spec.rb')).to eq(%w[spec/store_spec.rb])
  end

  it 'reads constant references from a long run of capitals in linear time' do
    write('spec/long_spec.rb', "#{'A' * 200_000}\nRSpec.describe Woods::Store do\nend\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(affected('lib/woods/store.rb')).to include('spec/long_spec.rb')
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
  end

  it 'ignores constant names in comments and ordinary strings' do
    write('spec/comment_spec.rb', "# Woods::Store\nRSpec.describe 'Woods::Store' do; end\n")

    expect(affected('lib/woods/store.rb')).not_to include('spec/comment_spec.rb')
  end

  it 'finds executable constant references nested in hash literals' do
    write('spec/hash_spec.rb', "RSpec.describe 'hash' do; it { {target: Woods::Store} }; end")

    expect(affected('lib/woods/store.rb')).to include('spec/hash_spec.rb')
  end

  it 'follows helper requires without suggesting the helper as a spec' do
    write('spec/support/store_helper.rb', "Woods::Store.new\n")
    write('spec/helper_spec.rb', "require_relative 'support/store_helper'\n")

    expect(affected('lib/woods/store.rb')).to include('spec/helper_spec.rb')
    expect(affected('spec/support/store_helper.rb')).to eq(['spec/helper_spec.rb'])
    expect(affected('lib/woods/store.rb')).not_to include('spec/support/store_helper.rb')
  end

  it 'follows the standard spec_helper load-path require through support files' do
    write('spec/support/store_helper.rb', 'Woods::Store.new')
    write('spec/spec_helper.rb', "require_relative 'support/store_helper'")
    write('spec/using_helper_spec.rb', "require 'spec_helper'")

    expect(affected('spec/support/store_helper.rb')).to eq(['spec/using_helper_spec.rb'])
  end

  %w[include extend].each do |operation|
    it "treats a module containing only #{operation} as a definition, not a namespace wrapper" do
      write('lib/woods/mixins_only.rb', "module Woods; module MixinsOnly; #{operation} Enumerable; end; end")
      write('lib/woods/mixin_consumer.rb', 'module Woods; class MixinConsumer; include MixinsOnly; end; end')
      write('spec/mixin_consumer_spec.rb', 'RSpec.describe Woods::MixinConsumer do; end')

      expect(affected('lib/woods/mixins_only.rb')).to eq(['spec/mixin_consumer_spec.rb'])
    end
  end

  it 'publishes parse failures even when a broken file still has a file unit' do
    write('lib/woods/broken.rb', 'class Broken; def run(')
    output = @root.join('map')
    Woods::GemMapper.new(root: @root, output_dir: output).map!
    Woods::PublishedIndex.open(output.to_s) do |index|
      expect(index.manifest.dig('self_map', 'parse_failures')).to include(
        include('path' => 'lib/woods/broken.rb', 'reason' => 'parse_error')
      )
    end
  end

  it 'does not publish spec source in the map' do
    output = @root.join('map')
    Woods::GemMapper.new(root: @root, output_dir: output).map!
    unit = Woods::PublishedIndex.open(output.to_s).unit('file:spec/store_spec.rb')

    expect(unit).to include('type' => 'ruby_file')
    expect(unit['source_code']).to be_nil
  end
end
