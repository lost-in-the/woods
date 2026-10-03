# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/view_template_extractor'
require 'woods/extractors/caller_prefix_partials'

# Rails looks a relative partial name up through the view prefixes of the
# controller rendering the page, not through the directory of the template
# that names it. A partial in a directory no controller owns therefore
# resolves differently per caller.
RSpec.describe Woods::Extractors::CallerPrefixPartials do
  include_context 'extractor setup'

  def controller(name, prefixes, parent: ActionController::Base, layout: nil)
    klass = Class.new(parent)
    klass.define_singleton_method(:_prefixes) { prefixes }
    klass.define_singleton_method(:_layout) { layout }
    stub_const(name, klass)
  end

  def units
    Woods::Extractors::ViewTemplateExtractor.new.extract_all
  end

  def unit(identifier)
    units.find { |candidate| candidate.identifier == identifier }
  end

  def render_targets(identifier)
    unit(identifier).dependencies.select { |dep| dep[:via] == :render }.map { |dep| dep[:target] }
  end

  before do
    stub_const('ActionController::Base', Class.new)
    controller('WidgetsController', %w[widgets application])
    controller('LedgersController', %w[ledgers application])
    create_file('app/views/shared/_navigation.html.erb', "<%= render 'account_head' %>\n")
  end

  context 'when one controller reaches the partial' do
    before do
      create_file('app/views/widgets/index.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')
    end

    it "targets the partial under that controller's prefix" do
      expect(render_targets('shared/_navigation.html.erb')).to eq(['widgets/_account_head.html.erb'])
    end

    it 'records nothing as unresolved' do
      expect(unit('shared/_navigation.html.erb').metadata).not_to have_key(:unresolved_partials)
    end

    it 'takes the first of the controller prefixes that holds the partial' do
      create_file('app/views/application/_account_head.html.erb', '<p>application</p>')
      create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')

      expect(render_targets('shared/_navigation.html.erb')).to eq(['widgets/_account_head.html.erb'])
    end

    it 'gives the single-file extraction the same unit' do
      path = File.join(tmp_dir, 'app/views/shared/_navigation.html.erb')
      single = Woods::Extractors::ViewTemplateExtractor.new.extract_view_template_file(path)

      expect(single.to_h).to eq(unit('shared/_navigation.html.erb').to_h)
    end
  end

  context 'when callers resolve the name to different files' do
    before do
      create_file('app/views/widgets/index.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/ledgers/index.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')
      create_file('app/views/ledgers/_account_head.html.erb', '<p>ledgers</p>')
    end

    it 'records no edge' do
      expect(render_targets('shared/_navigation.html.erb')).to eq([])
    end

    it 'records the name as unresolved, with every candidate' do
      expect(unit('shared/_navigation.html.erb').metadata[:unresolved_partials]).to eq(
        [{ kind: 'caller_prefix', name: 'account_head',
           candidates: %w[ledgers/_account_head.html.erb widgets/_account_head.html.erb] }]
      )
    end

    it 'gives the single-file extraction the same unit' do
      path = File.join(tmp_dir, 'app/views/shared/_navigation.html.erb')
      single = Woods::Extractors::ViewTemplateExtractor.new.extract_view_template_file(path)

      expect(single.to_h).to eq(unit('shared/_navigation.html.erb').to_h)
    end
  end

  context 'when several callers resolve the name to one file' do
    before do
      create_file('app/views/widgets/index.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/ledgers/index.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')
      controller('LedgersController', %w[ledgers widgets application])
    end

    it 'targets that file' do
      expect(render_targets('shared/_navigation.html.erb')).to eq(['widgets/_account_head.html.erb'])
    end
  end

  context 'when no caller reaches the partial' do
    it 'records no edge and an unresolved name with no candidate' do
      expect(render_targets('shared/_navigation.html.erb')).to eq([])
      expect(unit('shared/_navigation.html.erb').metadata[:unresolved_partials]).to eq(
        [{ kind: 'caller_prefix', name: 'account_head', candidates: [] }]
      )
    end
  end

  context 'when a caller reaches the partial but no prefix holds the file' do
    before { create_file('app/views/widgets/index.html.erb', "<%= render 'shared/navigation' %>\n") }

    it 'records no edge and an unresolved name with no candidate' do
      expect(render_targets('shared/_navigation.html.erb')).to eq([])
      expect(unit('shared/_navigation.html.erb').metadata[:unresolved_partials]).to eq(
        [{ kind: 'caller_prefix', name: 'account_head', candidates: [] }]
      )
    end
  end

  context 'when the page reaches the partial through another partial' do
    before do
      create_file('app/views/widgets/index.html.erb', "<%= render 'shared/shell' %>\n")
      create_file('app/views/shared/_shell.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')
    end

    it 'follows the render chain back to the controller' do
      expect(render_targets('shared/_navigation.html.erb')).to eq(['widgets/_account_head.html.erb'])
    end
  end

  context 'when the caller is only known through a partial resolved by this pass' do
    before do
      create_file('app/views/widgets/index.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/widgets/_account_head.html.erb', "<%= render 'shared/footer' %>\n")
      create_file('app/views/shared/_footer.html.erb', "<%= render 'legal' %>\n")
      create_file('app/views/widgets/_legal.html.erb', '<p>legal</p>')
    end

    it 'resolves the second partial through the first' do
      expect(render_targets('shared/_footer.html.erb')).to eq(['widgets/_legal.html.erb'])
    end
  end

  context 'when a layout renders the partial' do
    before do
      create_file('app/views/layouts/application.html.erb', "<%= render 'shared/navigation' %>\n<%= yield %>\n")
      create_file('app/views/widgets/index.html.erb', '<p>index</p>')
      create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')
    end

    it 'counts a controller whose implied layout it is' do
      controller('LedgersController', %w[ledgers application], layout: false)

      expect(render_targets('shared/_navigation.html.erb')).to eq(['widgets/_account_head.html.erb'])
    end

    it 'counts a controller that names the layout' do
      create_file('app/views/layouts/print.html.erb', "<%= render 'shared/navigation' %>\n")
      create_file('app/views/layouts/application.html.erb', '<%= yield %>')
      controller('WidgetsController', %w[widgets application], layout: 'print')

      expect(render_targets('shared/_navigation.html.erb')).to eq(['widgets/_account_head.html.erb'])
    end

    it 'does not count a controller that renders another layout' do
      create_file('app/views/layouts/widgets.html.erb', '<%= yield %>')

      expect(render_targets('shared/_navigation.html.erb')).to eq([])
    end
  end

  context 'with a partial name that carries a directory' do
    before { create_file('app/views/widgets/index.html.erb', "<%= render 'shipments/missing' %>\n") }

    it 'keeps the edge to the path as written' do
      expect(render_targets('widgets/index.html.erb')).to eq(['shipments/_missing.html.erb'])
    end
  end

  it 'settles three hundred callers of a fifty-partial chain within five seconds' do
    require 'woods/extracted_unit'
    template = lambda do |identifier, renders|
      Woods::ExtractedUnit.new(type: :view_template, identifier: identifier, file_path: identifier).tap do |built|
        built.namespace = File.dirname(identifier)
        built.metadata = {}
        built.dependencies = renders.map { |target| { type: :view_template, target: target, via: :render } }
      end
    end
    chain = (0...50).map { |index| "shared/_link#{index}.html.erb" }
    many = (0...300).map { |index| template.call("dir#{index}/index.html.erb", [chain.first]) }
    many += chain.each_with_index.map { |identifier, index| template.call(identifier, [chain[index + 1]].compact) }
    many.last.dependencies = [{ type: :view_template, target: 'shared/_tail.html.erb', via: :render }]
    owners = (0...300).to_h { |index| ["dir#{index}", { prefixes: ["dir#{index}", 'application'], layout: nil }] }
    resolver = ->(_identifier, prefixes, name) { "#{prefixes.first}/_#{name}.html.erb" }
    pending = { chain.last => [{ name: 'tail', target: 'shared/_tail.html.erb' }] }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.new(owners: owners, resolver: resolver).apply(many, pending)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    expect(many.last.dependencies).to eq([])
    expect(many.last.metadata[:unresolved_partials].first[:candidates].size).to eq(300)
  end

  it 'produces the same units on a repeat run' do
    create_file('app/views/widgets/index.html.erb', "<%= render 'shared/navigation' %>\n")
    create_file('app/views/ledgers/index.html.erb', "<%= render 'shared/navigation' %>\n")
    create_file('app/views/widgets/_account_head.html.erb', '<p>widgets</p>')
    create_file('app/views/ledgers/_account_head.html.erb', '<p>ledgers</p>')

    first = units.sort_by(&:identifier).map(&:to_h)
    second = units.sort_by(&:identifier).map(&:to_h)

    expect(second).to eq(first)
  end
end
