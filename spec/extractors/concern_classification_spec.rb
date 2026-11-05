# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/concern'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractor'
require 'woods/extractors/concern_classification'
require 'woods/extractors/concern_extractor'
require 'woods/extractors/poro_extractor'
require 'woods/extractors/lib_extractor'

# #996: a module is a concern when it extends ActiveSupport::Concern (checked
# at runtime, by name) or when it lives in a concerns directory. Every fact
# below is stated on its own; the booted incremental-equivalence spec checks
# that incremental runs reach the same answers.
RSpec.describe Woods::Extractors::ConcernClassification do
  include_context 'extractor setup'

  let(:models) { [] }
  let(:classification) { described_class.new }

  before do
    stub_const('ConcernRuleFixture', Module.new)
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: models))
  end

  def write(relative, source, load_it: true)
    path = create_file(relative, source)
    load path if load_it
    path
  end

  def shared(extractor)
    extractor.concern_classification = classification if extractor.respond_to?(:concern_classification=)
    extractor
  end

  # Every unit the three module-publishing families emit for one run sharing
  # one classification, as identifier => types.
  def published_types
    units = shared(Woods::Extractors::ConcernExtractor.new).extract_all +
            shared(Woods::Extractors::PoroExtractor.new).extract_all +
            shared(Woods::Extractors::LibExtractor.new).extract_all
    units.group_by(&:identifier).transform_values { |group| group.map(&:type) }
  end

  describe 'truth table: which family publishes a module' do
    rows = [
      # [fact, path, source, loaded, expected types]
      ['positive: extends ActiveSupport::Concern outside concerns/, nothing includes it',
       'app/models/rule/tracked.rb',
       "module ConcernRuleFixture::Tracked\n  extend ActiveSupport::Concern\n  def track; end\nend\n",
       true, [:concern]],
      ['positive: extends ::ActiveSupport::Concern (rooted)',
       'app/models/rule/rooted.rb',
       "module ConcernRuleFixture::Rooted\n  extend ::ActiveSupport::Concern\n  def rooted; end\nend\n",
       true, [:concern]],
      ['positive: an ActiveSupport::Concern with no method of its own',
       'app/models/rule/hooked.rb',
       "module ConcernRuleFixture::Hooked\n  extend ActiveSupport::Concern\n  included do\n  end\nend\n",
       true, [:concern]],
      ['positive: a plain module under concerns/ (the directory rule stays)',
       'app/models/concerns/rule_plain.rb',
       "module ConcernRuleFixture::RulePlain\n  def plain; end\nend\n",
       true, [:concern]],
      ['positive: a loaded ActiveSupport::Concern under lib/',
       'lib/rule/loaded_library.rb',
       "module ConcernRuleFixture::LoadedLibrary\n  extend ActiveSupport::Concern\n  def call; end\nend\n",
       true, [:concern]],
      ['near miss: the marker appears only in a comment',
       'app/models/rule/commented.rb',
       "module ConcernRuleFixture::Commented\n  # extend ActiveSupport::Concern\n  def commented; end\nend\n",
       true, [:poro]],
      ['near miss: the marker appears only in a string',
       'app/models/rule/quoted.rb',
       "module ConcernRuleFixture::Quoted\n  NOTE = 'extend ActiveSupport::Concern'\n  def quoted; end\nend\n",
       true, [:poro]],
      ['near miss: a plain module nothing includes',
       'app/models/rule/helper.rb',
       "module ConcernRuleFixture::Helper\n  def self.help; end\nend\n",
       true, [:poro]],
      ['near miss: under concerns/, hooks named only in comments',
       'app/models/concerns/rule_comment_only.rb',
       "module ConcernRuleFixture::RuleCommentOnly\n  # included do\n  # def nothing; end\nend\n",
       true, []],
      ['unknown: never loaded under lib/ keeps its lib type',
       'lib/rule/unloaded_library.rb',
       "module ConcernRuleFixture::UnloadedLibrary\n  extend ActiveSupport::Concern\n  def call; end\nend\n",
       false, [:lib]],
      ['unknown: never loaded under app/models keeps having no unit',
       'app/models/rule/unloaded.rb',
       "module ConcernRuleFixture::Unloaded\n  extend ActiveSupport::Concern\n  def call; end\nend\n",
       false, []]
    ]

    rows.each do |fact, path, source, loaded, expected|
      it "#{fact} -> #{expected.inspect}" do
        write(path, source, load_it: loaded)
        identifier = source[/module (\S+)/, 1]

        expect(published_types.fetch(identifier, [])).to eq(expected)
      end
    end
  end

  describe 'declaration ownership' do
    it 'retains reopened declarations and byte positions while refusing an unknown owner' do
      source = <<~RUBY
        # café
        module ConcernRuleFixture::Promoted; def first; end; end
        module ConcernRuleFixture::Sibling; def sibling; end; end
        module ConcernRuleFixture::Promoted; def second; end; end
      RUBY
      selected = Woods::Extractors::ConcernSource.new(source).for_owner('ConcernRuleFixture::Promoted')

      expect(selected.bytesize).to eq(source.bytesize)
      expect(selected.lines.size).to eq(source.lines.size)
      expect(selected).to include('def first', 'def second')
      expect(selected).not_to include('def sibling')
      expect(Woods::Extractors::ConcernSource.new(source).for_owner('Unknown')).to be_nil
    end

    it 'keeps a promoted concern independent of sibling methods and includes', :aggregate_failures do
      path = write('app/models/rule/shared.rb', <<~RUBY)
        module ConcernRuleFixture::SiblingMixin; end
        module ConcernRuleFixture::OwnedMixin; end
        module ConcernRuleFixture::Promoted
          extend ActiveSupport::Concern
          include ConcernRuleFixture::OwnedMixin
          def owned_instance; end
          module Helper
            include ConcernRuleFixture::SiblingMixin
            def helper_instance; end
          end
          class_methods do
            def from_block; end
          end
          module ClassMethods
            def from_module; end
          end
        end
        module ConcernRuleFixture::Sibling
          include ConcernRuleFixture::SiblingMixin
          def sibling_instance; end
          def self.sibling_class; end
        end
      RUBY
      unit = shared(Woods::Extractors::ConcernExtractor.new)
             .extract_model_mixin_file(path).find { |candidate| candidate.identifier == 'ConcernRuleFixture::Promoted' }

      expect(unit.metadata[:included_modules]).to eq(['ConcernRuleFixture::OwnedMixin'])
      expect(unit.dependencies.map { |edge| edge[:target] }).not_to include('ConcernRuleFixture::SiblingMixin')
      expect(unit.metadata[:instance_methods]).to include('owned_instance')
      expect(unit.metadata[:instance_methods]).not_to include('sibling_instance', 'helper_instance')
      expect(unit.metadata[:class_methods]).to contain_exactly('from_block', 'from_module')
    end
  end

  describe 'fixtures' do
    it 'publishes a nested concern and its concern dependency once each, joined by a concern edge' do
      write('app/models/rule/billing/ledgered.rb', <<~RUBY)
        module ConcernRuleFixture
          module Billing
            module Ledgered
              extend ActiveSupport::Concern
              def ledger; end
            end
          end
        end
      RUBY
      write('app/models/rule/billing/chargeable.rb', <<~RUBY)
        module ConcernRuleFixture::Billing::Chargeable
          extend ActiveSupport::Concern
          include ConcernRuleFixture::Billing::Ledgered
          def charge; end
        end
      RUBY

      types = published_types
      expect(types).to include('ConcernRuleFixture::Billing::Ledgered' => [:concern],
                               'ConcernRuleFixture::Billing::Chargeable' => [:concern])
      expect(types).not_to have_key('ConcernRuleFixture::Billing')
      concerns = shared(Woods::Extractors::ConcernExtractor.new).extract_all
      chargeable = concerns.find { |unit| unit.identifier == 'ConcernRuleFixture::Billing::Chargeable' }
      expect(chargeable.dependencies)
        .to include(type: :concern, target: 'ConcernRuleFixture::Billing::Ledgered', via: :include)
      expect(chargeable.metadata).to include(concern_type: 'active_support', uses_active_support: true)
    end

    it 'publishes a concern a live model prepends once, though both rules reach it' do
      write('app/models/rule/stamped.rb', <<~RUBY)
        module ConcernRuleFixture::Stamped
          extend ActiveSupport::Concern
          def save; super; end
        end
      RUBY
      models << Class.new { prepend ConcernRuleFixture::Stamped }

      expect(published_types.fetch('ConcernRuleFixture::Stamped')).to eq([:concern])
      expect(classification.runtime_modules { {} }.values.flatten.count { |mod| mod == ConcernRuleFixture::Stamped })
        .to eq(1)
    end

    it 'keeps a promoted concern a concern when nothing includes it, beside a PORO sibling in its file' do
      write('app/models/rule/shared.rb', <<~RUBY)
        module ConcernRuleFixture::Promoted
          extend ActiveSupport::Concern
          def promoted; end
        end
        module ConcernRuleFixture::Sibling
          def self.sibling; end
        end
      RUBY

      expect(published_types).to include('ConcernRuleFixture::Promoted' => [:concern],
                                         'ConcernRuleFixture::Sibling' => [:poro])
    end

    it 'never publishes one module under two types across every fixture at once' do
      write('app/models/rule/a.rb', "module ConcernRuleFixture::A\n  extend ActiveSupport::Concern\nend\n")
      write('app/models/rule/b.rb', "module ConcernRuleFixture::B\n  extend ::ActiveSupport::Concern\nend\n")
      write('app/models/c.rb', "module ConcernRuleFixture::C\n  # extend ActiveSupport::Concern\n  def c; end\nend")
      write('lib/rule/d.rb', "module ConcernRuleFixture::D\n  extend ActiveSupport::Concern\n  def d; end\nend\n")
      write('lib/rule/e.rb', "module ConcernRuleFixture::E\n  def e; end\nend\n")
      write('app/models/concerns/rule_f.rb', "module ConcernRuleFixture::RuleF\n  def f; end\nend\n")
      models << Class.new { include ConcernRuleFixture::C }

      types = published_types
      expect(types.values).to all(satisfy { |list| list.size == 1 })
      expect(types).to include('ConcernRuleFixture::A' => [:concern], 'ConcernRuleFixture::B' => [:concern],
                               'ConcernRuleFixture::C' => [:concern], 'ConcernRuleFixture::D' => [:concern],
                               'ConcernRuleFixture::E' => [:lib], 'ConcernRuleFixture::RuleF' => [:concern])
    end
  end

  describe '#concern_answer' do
    it 'answers true, false or unknown by name, without autoloading' do
      write('app/models/rule/yes.rb', "module ConcernRuleFixture::Yes\n  extend ActiveSupport::Concern\nend\n")
      write('app/models/rule/no.rb', "module ConcernRuleFixture::No\nend\n")
      ConcernRuleFixture.autoload(:Lazy, create_file('app/models/rule/lazy.rb', 'raise "must never load"'))

      expect(classification.concern_answer('ConcernRuleFixture::Yes')).to be(true)
      expect(classification.concern_answer('::ConcernRuleFixture::Yes')).to be(true)
      expect(classification.concern_answer('ConcernRuleFixture::No')).to be(false)
      expect(classification.concern_answer('ConcernRuleFixture::Missing')).to be_nil
      expect(classification.concern_answer('ConcernRuleFixture::Lazy')).to be_nil
      expect(classification.concern_answer('String')).to be_nil
    end

    it 'never trusts a module that overrides singleton_class or include?' do
      write('app/models/rule/liar.rb', <<~RUBY)
        module ConcernRuleFixture::Liar
          def self.singleton_class = raise('must never run')
          def self.include?(*) = true
        end
      RUBY

      expect(classification.concern_answer('ConcernRuleFixture::Liar')).to be(false)
    end
  end

  describe 'one classification per run' do
    it 'computes the mixin and promoted sets once for the concern, PORO and library families' do
      write('app/models/rule/once.rb', "module ConcernRuleFixture::Once\n  extend ActiveSupport::Concern\nend\n")
      discoveries = 0
      allow_any_instance_of(Woods::Extractors::ConcernExtractor).to(
        receive(:discover_model_mixin_paths).and_wrap_original { |original| (discoveries += 1) && original.call }
      )
      parses = 0
      allow_any_instance_of(described_class).to(
        receive(:discover_promoted).and_wrap_original { |original| (parses += 1) && original.call }
      )

      published_types
      shared(Woods::Extractors::PoroExtractor.new).standalone_modules
      shared(Woods::Extractors::LibExtractor.new).claimed_identifiers

      expect([discoveries, parses]).to eq([1, 1])
      expect(classification.stats).to include(promoted: 1)
    end

    it 'is the same object for every extractor the orchestrator builds in a run' do
      extractor = Woods::Extractor.new(output_dir: File.join(tmp_dir, 'index'))
      concerns, poros, libs = %i[concerns poros libs].map { |key| extractor.send(:extractor_for, key) }
      shared = [poros, libs].map { |family| family.instance_variable_get(:@concern_classification) }
      shared << concerns.classification

      expect(shared.uniq.size).to eq(1)
      expect(shared.first).to be_a(described_class)
    end
  end
end
