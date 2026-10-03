# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/test_mapping_extractor'
require 'woods/extractors/test_support_extractor'

# Ruby 3.2+ memoizes backtracking, which hides polynomial patterns; the
# timeout still catches them, and Ruby < 3.2 runs under a wall-clock budget.
RSpec.describe 'test support and test mapping regex complexity' do
  include_context 'extractor setup'

  def within_budget(&block)
    if Regexp.respond_to?(:timeout=)
      previous = Regexp.timeout
      Regexp.timeout = 1.0
      begin
        block.call
      ensure
        Regexp.timeout = previous
      end
    else
      Timeout.timeout(5, &block)
    end
  end

  let(:catalog) { Woods::Extractors::TestSupportCatalog }

  it 'scans support definitions in linear time over blank lines and near misses' do
    within_budget do
      patterns = %i[SHARED_EXAMPLES SHARED_CONTEXT MATCHER CONFIGURE METHOD CONFIG_INCLUDE BEHAVES_LIKE
                    INCLUDE_CONTEXT INCLUDE_MODULE].map { |name| catalog.const_get(name) }
      patterns.each do |pattern|
        expect("\n" * 50_000).not_to match(pattern)
        expect(" \t\n" * 50_000).not_to match(pattern)
        expect("#{" \t" * 50_000}x").not_to match(pattern)
        expect("  shared_example\n  include_contex\n  matche\n  de\n  c.includ\n" * 10_000).not_to match(pattern)
      end
    end
  end

  it 'reads names, includes, and include types in linear time' do
    within_budget do
      expect("shared_examples \"#{'a' * 50_000}\n".scan(catalog::SHARED_EXAMPLES)).to eq([])
      expect("shared_examples #{'(' * 50_000}\n".scan(catalog::SHARED_EXAMPLES)).to eq([])
      expect(("  it_behaves_like 'x\n" * 10_000).scan(catalog::BEHAVES_LIKE)).to eq([])
      expect("#{'a' * 50_000}\n#{'a_' * 25_000}\n".scan(catalog::CONFIG_INCLUDE)).to eq([])
      expect("c.include #{'A::' * 20_000}a\n".scan(catalog::CONFIG_INCLUDE).size).to eq(1)
      expect("RSpec.configure { |#{'c' * 50_000}\n".scan(catalog::INCLUDE_MODULE)).to eq([])
      expect(catalog::INCLUDE_TYPES.match?(":type#{' ' * 50_000}")).to be(false)
      expect(catalog::INCLUDE_TYPES.match?(':type ' * 20_000)).to be(false)
    end
  end

  it 'resolves references in a large source in linear time' do
    create_file('spec/support/matchers.rb', <<~RUBY)
      RSpec::Matchers.define :have_combobox do
      end
      RSpec::Matchers.define :have_combobox_option do
      end
    RUBY
    references = catalog.new.method(:references)

    within_budget do
      expect(references.call('have_combobo ' * 50_000).matchers).to eq([])
      expect(references.call('have_combobox_optio' * 20_000).matchers).to eq([])
      expect(references.call("#{'x.' * 50_000}have_combobox").matchers).to eq([])
      expect(references.call("expect(page).to have_combobox\n" * 10_000).matchers).to eq(['have_combobox'])
    end
  end

  it 'counts examples and reads Minitest subjects in linear time' do
    extractor = Woods::Extractors::TestMappingExtractor.new
    sources = ["\n" * 50_000, " \t\n" * 50_000, "  scenari\n  tes\n  de\n" * 10_000,
               "class #{'a' * 50_000}", "class#{' ' * 50_000}", 'class aTes ' * 10_000,
               "#{"\n" * 50_000}  shared_examples_fo"]

    within_budget do
      sources.each_with_index do |source, index|
        path = create_file("test/models/big_#{index}_test.rb", source)
        spec = create_file("spec/models/big_#{index}_spec.rb", source)
        expect(extractor.extract_test_file(path).metadata[:test_count]).to eq(0)
        expect(extractor.extract_test_file(spec).metadata[:test_count]).to eq(0)
      end
    end
  end

  it 'scans navigation calls in linear time' do
    stub_route_set(
      [route_double(verb: 'GET', path: '/widgets/:id', controller: 'widgets', action: 'show', name: 'widget'),
       route_double(verb: 'GET', path: '/files/*path/:a-:b', controller: 'files', action: 'show')],
      root: rails_root, logger: logger
    )
    exercised = Woods::Extractors::TestRouteResolver.new.method(:exercised)

    within_budget do
      expect(exercised.call('visit ' * 50_000)).to eq([])
      expect(exercised.call('get(' * 50_000)).to eq([])
      expect(exercised.call("visit #{'a_' * 25_000}")).to eq([])
      expect(exercised.call("visit widget_pat\nget widget_ur\n" * 10_000)).to eq([])
      expect(exercised.call("get#{'(' * 50_000}")).to eq([])
      expect(exercised.call("visit \"/#{'#{' * 25_000}\"")).to eq([])
      expect(exercised.call("visit \"/#{"\#{x}" * 12_000}\"")).to eq([])
      expect(exercised.call("visit \"/files/x/#{'a-' * 200}b\"\n" * 2_000)).to eq(['GET /files/*path/:a-:b'])
      expect(exercised.call("visit \"/#{'a' * 50_000}")).to eq([])
      expect(exercised.call("visit widget_path(w)\n" * 10_000)).to eq(['GET /widgets/:id'])
    end
  end

  it 'parses factory options in linear time' do
    extractor = Woods::Extractors::FactoryExtractor.new
    sources = ["factory :widget, aliases: [#{':a, ' * 20_000}\n", "factory :widget, aliases:#{' ' * 50_000}\n",
               "factory :widget, #{'aliases: ' * 10_000}\n", "factory :widget, class: #{'::' * 25_000}\n"]

    within_budget do
      sources.each do |source|
        path = create_file('spec/factories/widgets.rb', source)
        expect(extractor.extract_factory_file(path).map(&:identifier)).to eq(['widget'])
      end
    end
  end
end
