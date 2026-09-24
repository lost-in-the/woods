# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/source_nesting'
require 'zeitwerk'
require 'tmpdir'
require 'fileutils'

RSpec.describe Woods::Extractors::SourceNesting, 'loader ownership' do
  subject(:scanner) { Class.new { include Woods::Extractors::SourceNesting }.new }

  let(:source) do
    <<~RUBY
      module API
        class Container
          class Parser
          end
        end
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir('woods_loader_ownership') do |root|
      @root = root
      example.run
    end
  end

  def rails_loaders(main:, once:, root: @root)
    stub_const('Rails', double('Rails', root: root, autoloaders: double('autoloaders', main: main, once: once)))
  end

  def write_source(relative, content = source)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  %i[main once].each do |owner|
    context "with the #{owner} loader owning the file" do
      before do
        @main = Zeitwerk::Loader.new
        @once = Zeitwerk::Loader.new
        rails_loaders(main: @main, once: @once)
      end

      after do
        @main.unregister
        @once.unregister
      end

      let(:loader) { owner == :main ? @main : @once }

      it 'uses the owning loader inflection for a declared child inside class wrappers' do
        path = write_source('lib/api/container/parser.rb')
        loader.push_dir(File.join(@root, 'lib'))
        loader.inflector.inflect('api' => 'API')

        expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
      end

      it 'uses the owning root namespace' do
        stub_const('API', Module.new)
        content = "module API\n  class Container\n  end\nend\n"
        path = write_source('lib/container.rb', content)
        loader.push_dir(File.join(@root, 'lib'), namespace: API)

        expect(scanner.governed_class_name(path, content)).to eq('API::Container')
      end

      it 'honors the owning loader collapsed directories' do
        path = write_source('lib/actions/api/container/parser.rb')
        loader.push_dir(File.join(@root, 'lib'))
        loader.inflector.inflect('api' => 'API')
        loader.collapse(File.join(@root, 'lib/actions'))

        expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
      end

      it 'preserves ignored files and ignored ancestor directories as authoritative non-claims' do
        file = write_source('lib/api/container/parser.rb')
        nested = write_source('lib/ignored/api/container/parser.rb')
        loader.push_dir(File.join(@root, 'lib'))
        loader.inflector.inflect('api' => 'API')
        loader.ignore(file, File.join(@root, 'lib/ignored'))

        expect(scanner.governed_class_name(file, source)).to be_nil
        expect(scanner.governed_class_name(nested, source)).to be_nil
      end

      it 'does not invent a declaration for a VERSION-only namespace file' do
        content = "module Acme\n  VERSION = '1.0'\nend\n"
        path = write_source('lib/acme/version.rb', content)
        loader.push_dir(File.join(@root, 'lib'))

        expect(scanner.governed_class_name(path, content)).to be_nil
      end
    end
  end

  it 'checks direct once ownership before considering a foreign main root' do
    main = double('main', dirs: ['/boot/app/services'])
    once = double('once', dirs: [File.join(@root, 'app/services')])
    path = write_source('app/services/api/container/parser.rb')
    expect(main).not_to receive(:cpath_expected_at)
    expect(once).to receive(:cpath_expected_at).with(path).and_return('API::Container::Parser')
    rails_loaders(main: main, once: once)

    expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
  end

  it 'leaves equally owned direct roots unmanaged' do
    path = write_source('app/services/api/container/parser.rb')
    main = double('main', dirs: [File.join(@root, 'app/services')])
    once = double('once', dirs: main.dirs)
    allow(main).to receive(:cpath_expected_at).and_return('API::Container::Parser')
    allow(once).to receive(:cpath_expected_at).and_return('API::Container::Parser')
    rails_loaders(main: main, once: once)

    expect(scanner.governed_class_name(path, source)).to be_nil
  end

  it 'respects the most specific direct root across loaders' do
    path = write_source('lib/nested/api/container/parser.rb')
    main = double('main', dirs: [File.join(@root, 'lib')])
    once = double('once', dirs: [File.join(@root, 'lib/nested')])
    expect(main).not_to receive(:cpath_expected_at)
    expect(once).to receive(:cpath_expected_at).with(path).and_return('API::Container::Parser')
    rails_loaders(main: main, once: once)

    expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
  end

  [nil, :unsupported, :error].each do |answer|
    it "does not fall back when the owning once loader returns #{answer.inspect}" do
      inflector = Zeitwerk::Inflector.new
      inflector.inflect('api' => 'API')
      main = double('main', dirs: ['/boot/app/services'], inflector: inflector)
      once = double('once', dirs: [File.join(@root, 'app/services')])
      path = write_source('app/services/api/container/parser.rb')
      if answer == :error
        allow(once).to receive(:cpath_expected_at).and_raise(StandardError, 'cannot derive name')
      elsif answer != :unsupported
        allow(once).to receive(:cpath_expected_at).and_return(answer)
      end
      rails_loaders(main: main, once: once)

      expect(scanner.governed_class_name(path, source)).to be_nil
    end
  end

  it 'keeps an empty authoritative root set unmanaged' do
    rails_loaders(main: double(dirs: []), once: double(dirs: []))

    expect(scanner.governed_class_name(File.join(@root, 'app/services/api/container/parser.rb'), source)).to be_nil
  end

  context 'when both loaders belong to a different application tree' do
    let(:active) { File.join(@root, 'active') }
    let(:path) { File.join(active, 'app/services/api/container/parser.rb') }
    let(:once_root) { File.join(@root, 'boot/app/services') }
    let(:once) { double('once', dirs: [once_root]) }
    let(:main) { double('main', dirs: [File.join(@root, 'boot/app/models')]) }

    before do
      rails_loaders(main: main, once: once, root: active)
      inflector = Zeitwerk::Inflector.new
      inflector.inflect('api' => 'API')
      allow(once).to receive(:inflector).and_return(inflector)
    end

    it 'uses the once loader for an existing mapped file' do
      mapped = write_source('boot/app/services/api/container/parser.rb')
      expect(once).to receive(:cpath_expected_at).with(mapped).and_return('API::Container::Parser')

      expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
    end

    it 'preserves a mapped once loader authoritative non-claim' do
      mapped = write_source('boot/app/services/api/container/parser.rb')
      expect(once).to receive(:cpath_expected_at).with(mapped).and_return(nil)

      expect(scanner.governed_class_name(path, source)).to be_nil
    end

    it 'uses the once inflector for an unambiguous copied-only file' do
      expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
    end

    it 'does not guess when copied-only roots across the two loaders are ambiguous' do
      allow(main).to receive(:dirs).and_return([File.join(@root, 'other/app/services')])
      inflector = Zeitwerk::Inflector.new
      inflector.inflect('api' => 'API')
      allow(main).to receive(:inflector).and_return(inflector)

      expect(scanner.governed_class_name(path, source)).to be_nil
    end

    it 'selects the single existing mapped file across both loaders' do
      allow(main).to receive(:dirs).and_return([File.join(@root, 'other/app/services')])
      mapped = write_source('boot/app/services/api/container/parser.rb')
      expect(once).to receive(:cpath_expected_at).with(mapped).and_return('API::Container::Parser')

      expect(scanner.governed_class_name(path, source)).to eq('API::Container::Parser')
    end

    it 'does not guess when both loaders have an existing mapped file' do
      allow(main).to receive(:dirs).and_return([File.join(@root, 'other/app/services')])
      write_source('other/app/services/api/container/parser.rb')
      write_source('boot/app/services/api/container/parser.rb')
      allow(main).to receive(:cpath_expected_at).and_return('API::Container::Parser')

      expect(scanner.governed_class_name(path, source)).to be_nil
    end

    it 'refuses a copied-only file under a namespaced once root' do
      allow(once).to receive(:dirs).with(namespaces: true).and_return(once_root => Module.new)

      expect(scanner.governed_class_name(path, source)).to be_nil
    end

    it 'refuses a copied-only path through an owning once collapse' do
      allow(once).to receive(:__collapse?).with(File.join(once_root, 'api')).and_return(true)

      expect(scanner.governed_class_name(path, source)).to be_nil
    end

    it 'refuses a copied-only path crossing a nested once root' do
      allow(once).to receive(:dirs).and_return([once_root, File.join(once_root, 'api')])

      expect(scanner.governed_class_name(path, source)).to be_nil
    end

    it 'does not infer a copied root when the other loader belongs to the active tree' do
      allow(main).to receive(:dirs).and_return([File.join(active, 'app/models')])

      expect(scanner.governed_class_name(path, source)).to be_nil
    end
  end
end
