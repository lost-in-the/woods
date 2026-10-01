# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/extractors/component_discovery'

RSpec.describe Woods::Extractors::ComponentDiscovery do
  let(:root) { Dir.mktmpdir('woods_component_discovery') }
  let(:logger) { instance_spy(Logger) }
  let(:autoload_paths) { [File.join(root, 'app', 'components'), File.join(root, 'app', 'views')] }
  let(:host) { Class.new { include Woods::Extractors::ComponentDiscovery }.new }
  let(:autoloaders) { [] }

  before do
    require 'active_support/core_ext/string/inflections'
    # A fresh instance, not the shared one: spec_helper's around hook restores
    # the object that existed before the example, so mutating it here would
    # leak into every later example.
    Woods.configuration = Woods::Configuration.new
    config = double('Config', autoload_paths: autoload_paths, eager_load_paths: [], autoload_once_paths: [])
    application = double('Application', config: config)
    stub_const('Rails', double('Rails', root: Pathname.new(root), logger: logger, application: application,
                                        autoloaders: autoloaders))
  end

  after { FileUtils.rm_rf(root) }

  # `Rails.logger.debug` is called with a block, so the spy records no
  # arguments. Capture what the block would have written instead.
  let(:debug_messages) { [] }

  before do
    allow(logger).to receive(:debug) { |*args, &block| debug_messages << (block ? block.call : args.first) }
  end

  def write(relative, contents = "# component\n")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  describe 'the constant a file implies' do
    it 'derives it from the autoload root that owns the file' do
      path = write('app/views/ui/card_component.rb')

      expect(host.send(:component_constant_name, path)).to eq('Ui::CardComponent')
    end

    it 'prefers the longest matching autoload root' do
      autoload_paths << File.join(root, 'app', 'views', 'components')
      path = write('app/views/components/ui/card_component.rb')

      expect(host.send(:component_constant_name, path)).to eq('Ui::CardComponent')
    end

    it 'is nil for a file no autoload root owns' do
      path = write('lib/loose/thing.rb')

      expect(host.send(:component_constant_name, path)).to be_nil
    end

    # The Rails-guide inflection (`api_card` => `APICard`): camelize answers
    # `Ui::ApiCard`, which resolves to nothing, so the component was never
    # loaded and silently missing from both families (F16).
    it 'asks the owning loader first, so an inflected name resolves as Rails resolves it' do
      path = write('app/views/ui/api_card.rb')
      main = double('main loader')
      allow(main).to receive(:cpath_expected_at) { |asked| asked == path ? 'Ui::APICard' : nil }
      autoloaders << main

      expect(host.send(:component_constant_name, path)).to eq('Ui::APICard')
    end

    it 'falls back to camelize when no loader names the file or the loader predates cpath_expected_at' do
      path = write('app/views/ui/api_card.rb')
      silent = double('loader without an answer')
      allow(silent).to receive(:cpath_expected_at).and_return(nil)
      old = double('zeitwerk 2.5 loader')
      autoloaders.push(silent, old)

      expect(host.send(:component_constant_name, path)).to eq('Ui::ApiCard')
    end

    it 'falls back to camelize when the loader raises for the path' do
      path = write('app/views/ui/api_card.rb')
      failing = double('loader')
      allow(failing).to receive(:cpath_expected_at).and_raise(StandardError, 'does not exist')
      autoloaders << failing

      expect(host.send(:component_constant_name, path)).to eq('Ui::ApiCard')
    end
  end

  describe '#load_component_files' do
    it 'asks the autoloader for every Ruby file under the component directories' do
      first = write('app/components/badge_component.rb')
      second = write('app/views/ui/card_component.rb')

      expect(host).to receive(:constantize_component_file).with(first)
      expect(host).to receive(:constantize_component_file).with(second)

      host.load_component_files
    end

    it 'ignores files that are not Ruby' do
      write('app/views/ui/card_component.html.erb')

      expect(host).not_to receive(:constantize_component_file)

      host.load_component_files
    end

    it 'walks nothing when the directories are absent' do
      expect(host).not_to receive(:constantize_component_file)

      host.load_component_files
    end

    it 'walks nothing when the configured list is empty' do
      Woods.configuration.component_paths = []
      write('app/components/badge_component.rb')

      expect(host).not_to receive(:constantize_component_file)

      host.load_component_files
    end

    # `app/views/components` sits under `app/views`, and both are defaults, so
    # the recursive glob handed every file below the former to the autoloader
    # twice.
    it 'walks a nested configured directory once' do
      nested = write('app/views/components/ui/card_component.rb')

      expect(host).to receive(:constantize_component_file).with(nested).once

      host.load_component_files
    end

    it 'says once how many files resolved to no constant' do
      write('lib/loose/thing.rb')
      Woods.configuration.component_paths = ['lib/loose']

      host.load_component_files

      # Logged through a block, so the string is never built on a logger that
      # would drop it.
      expect(debug_messages.size).to eq(1)
      expect(debug_messages.first).to match(/1 component file/)
    end

    it 'stays quiet when every file resolved' do
      write('app/views/ui/card_component.rb')
      stub_const('Ui::CardComponent', Class.new)

      host.load_component_files

      expect(debug_messages).to be_empty
    end

    it 'counts a file whose expected constant does not resolve as unresolved and names it (F16)' do
      path = write('app/views/ui/api_card.rb')

      host.load_component_files

      expect(debug_messages).to include(a_string_matching(/#{Regexp.escape(path)}.*Ui::ApiCard/))
      expect(debug_messages).to include(a_string_matching(/1 component file.*no constant/))
      expect(debug_messages.grep(/not on an autoload path/)).to be_empty
    end

    it 'honours a configured directory list' do
      Woods.configuration.component_paths = ['app/widgets']
      autoload_paths << File.join(root, 'app', 'widgets')
      write('app/components/badge_component.rb')
      widget = write('app/widgets/badge_widget.rb')

      expect(host).to receive(:constantize_component_file).with(widget).once

      host.load_component_files
    end

    it 'survives a component file that will not load' do
      write('app/views/ui/card_component.rb')
      allow_any_instance_of(String).to receive(:safe_constantize).and_raise(SyntaxError, 'unexpected end')

      expect { host.load_component_files }.not_to raise_error
      expect(logger).to have_received(:warn).with(/Could not load component file/)
    end
  end

  describe '#component_paths' do
    it 'defaults to the component directories Rails apps actually use' do
      Woods.configuration.component_paths = nil

      expect(host.component_paths).to eq(described_class::DEFAULT_COMPONENT_PATHS)
    end

    it 'walks nothing when the configured list is empty' do
      Woods.configuration.component_paths = []

      expect(host.component_paths).to eq([])
    end
  end
end
