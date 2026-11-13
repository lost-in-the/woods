# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'active_support'
require 'active_support/concern'
require 'active_support/core_ext/module/introspection'
require 'woods'
require 'woods/method_table'
require 'woods/file_lines'
require 'woods/source_line_map'
require 'woods/extractors/model_extractor'
require 'woods/extractors/controller_extractor'
require 'woods/mcp/lookup_member'

# Fixture classes and modules for the lookup member runtime oracle.
module LookupMemberOracle
  def self.path_of(name)
    declaration = /(?:module|class) #{name.split('::').last}\b/
    LookupMemberOracle::FIXTURES.find { |_, source| source.match?(declaration) }&.first
  end
end

# path => source. Each is evaluated under its path, so `source_location`
# names the same file and line the published unit maps to.
LookupMemberOracle::FIXTURES = {
  'app/models/concerns/lookup_oracle/linking.rb' => <<~RUBY,
    module LookupOracle
      module Linking
        extend ActiveSupport::Concern

        def link_target
          :linking
        end

        class_methods do
          def link_scope
            :linking
          end
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/stamping.rb' => <<~RUBY,
    module LookupOracle
      module Stamping
        extend ActiveSupport::Concern

        def stamp
          :stamping
        end

        def self.stamp_registry
          :registry
        end

        class_methods do
          def stamp_all
            :stamping
          end
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/tagging.rb' => <<~RUBY,
    module LookupOracle
      module Tagging
        extend ActiveSupport::Concern

        def tag_label
          :tagging
        end

        def shared_name
          :tagging
        end

        class_methods do
          def finder_for
            :tagging
          end
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/sorting.rb' => <<~RUBY,
    module LookupOracle
      module Sorting
        extend ActiveSupport::Concern

        def shared_name
          :sorting
        end

        class_methods do
          def finder_for
            :sorting
          end
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/grouping.rb' => <<~RUBY,
    module LookupOracle
      module Grouping
        extend ActiveSupport::Concern

        def shared_name
          :grouping
        end

        private

        def group_key
          :grouping
        end

        class_methods do
          def finder_for
            :grouping
          end
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/auditing.rb' => <<~RUBY,
    module LookupOracle
      module Auditing
        extend ActiveSupport::Concern

        def save_record
          :auditing
        end

        class_methods do
          def build_record
            :auditing
          end
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/signing.rb' => <<~RUBY,
    module LookupOracle
      module Signing
        extend ActiveSupport::Concern

        def seal
          :signing
        end
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/sealing.rb' => <<~RUBY,
    module LookupOracle
      module Sealing
        extend ActiveSupport::Concern

        def seal
          :sealing
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/sealed_record.rb' => <<~RUBY,
    module LookupOracle
      class SealedRecord
        prepend Signing
        prepend Sealing

        def seal
          :own
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/co_sealed_record.rb' => <<~RUBY,
    module LookupOracle
      class CoSealedRecord < SealedRecord
        prepend Signing, Sealing
      end
    end
  RUBY
  'app/models/lookup_oracle/twice_sealed_record.rb' => <<~RUBY,
    module LookupOracle
      class TwiceSealedRecord
        prepend Signing, Sealing

        def seal
          :own
        end
      end
    end
  RUBY
  'lib/lookup_oracle/helpers.rb' => <<~RUBY,
    module LookupOracle
      module Helpers
        module_function

        def tidy_text
          :helpers
        end
      end
    end
  RUBY
  'lib/lookup_oracle_tracing.rb' => <<~RUBY,
    module LookupOracleTracing
      def trace_call
        :tracing
      end
    end
  RUBY
  'app/models/lookup_oracle/base_record.rb' => <<~RUBY,
    module LookupOracle
      class BaseRecord
        include Linking

        def base_only
          :base
        end

        def self.base_scope
          :base
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/mid_record.rb' => <<~RUBY,
    module LookupOracle
      class MidRecord < BaseRecord
        def link_target
          :mid
        end

        def stamp
          :mid
        end

        def self.link_scope
          :mid
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/leaf_record.rb' => <<~RUBY,
    module LookupOracle
      class LeafRecord < MidRecord
        include Stamping
        include Tagging
        include Sorting
        include Grouping

        def own_thing
          :leaf
        end

        def self.leaf_scope
          :leaf
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/prepended_record.rb' => <<~RUBY,
    module LookupOracle
      class PrependedRecord
        prepend Auditing
        include Helpers

        def save_record
          :own
        end

        def self.build_record
          :own
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/traced_record.rb' => <<~RUBY,
    module LookupOracle
      class TracedRecord
        prepend LookupOracleTracing
        include Tagging

        def trace_call
          :own
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/hidden_base.rb' => <<~RUBY,
    module LookupOracle
      class HiddenBase
        include Tagging

        def tag_label
          :hidden
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/orphan_record.rb' => <<~RUBY,
    module LookupOracle
      class OrphanRecord < HiddenBase
        def orphan_own
          :orphan
        end
      end
    end
  RUBY
  'app/controllers/lookup_oracle/base_controller.rb' => <<~RUBY,
    module LookupOracle
      class BaseController
        include Linking
      end
    end
  RUBY
  'app/controllers/lookup_oracle/mid_controller.rb' => <<~RUBY,
    module LookupOracle
      class MidController < BaseController
        def link_target
          :mid
        end
      end
    end
  RUBY
  'app/controllers/lookup_oracle/leaf_controller.rb' => <<~RUBY
    module LookupOracle
      class LeafController < MidController
        include Stamping
        include Tagging
        include Sorting
        include Grouping

        def index
          :leaf
        end
      end
    end
  RUBY
}.freeze

# Modules the extractors would treat as application concerns. The top-level
# tracing module is application code but not a concern, so it is not inlined.
LookupMemberOracle::CONCERNS = %w[Linking Stamping Tagging Sorting Grouping Auditing Signing Sealing Helpers]
                               .map { |name| "LookupOracle::#{name}" }.freeze

# [identifier, type]; HiddenBase is deliberately not published.
LookupMemberOracle::UNITS = [
  %w[LookupOracle::BaseRecord model], %w[LookupOracle::MidRecord model], %w[LookupOracle::LeafRecord model],
  %w[LookupOracle::PrependedRecord model], %w[LookupOracle::TracedRecord model],
  %w[LookupOracle::OrphanRecord model], %w[LookupOracle::SealedRecord model],
  %w[LookupOracle::CoSealedRecord model], %w[LookupOracle::TwiceSealedRecord model],
  %w[LookupOracle::BaseController controller], %w[LookupOracle::MidController controller],
  %w[LookupOracle::LeafController controller],
  %w[LookupOracle::Stamping concern], %w[LookupOracle::Tagging concern], %w[LookupOracle::Grouping concern],
  %w[LookupOracle::Helpers lib]
].freeze

# Every method name the fixtures define, asked of every unit as `#` and `.`.
LookupMemberOracle::NAMES = LookupMemberOracle::FIXTURES.values.flat_map do |source|
  source.scan(/def (?:self\.)?(\w+)/).flatten
end.uniq.freeze

# The rule `lookup` holds for `Owner#name` and `Owner.name`: a member answer
# names the method the owner really responds to, and where the published
# index cannot establish that, the answer says so instead of guessing.
#
# The oracle defines real classes and modules from fixture source text,
# builds each one's unit the way extraction publishes it (the extractors' own
# concern selection, ordering and inlining, then the method table and file
# lines over the result), and compares every lookup answer with the runtime:
# whether the owner responds to the name, which definition it calls (file and
# line from `source_location`) and its visibility.
RSpec.describe 'MCP lookup member answers against the Ruby runtime' do
  before(:context) do
    LookupMemberOracle::FIXTURES.each { |path, source| TOPLEVEL_BINDING.eval(source, path, 1) }
  end

  after(:context) do
    Object.send(:remove_const, :LookupOracle)
    Object.send(:remove_const, :LookupOracleTracing)
  end

  before { stub_const('Rails', Module.new.tap { |rails| rails.define_singleton_method(:root) { Pathname('/app') } }) }

  # The model extractor's own selection and order (`included_modules`, most
  # recently included first), with the application checks answered for the
  # fixtures.
  def model_modules(klass)
    extractor = Woods::Extractors::ModelExtractor.allocate
    extractor.define_singleton_method(:app_source?) { |*| true }
    extractor.define_singleton_method(:defined_in_app?) { |mod| LookupMemberOracle::CONCERNS.include?(mod.name) }
    extractor.send(:extract_included_modules, klass)
  end

  # The controller extractor's own selection and order (sorted by name).
  def controller_modules(klass)
    extractor = Woods::Extractors::ControllerExtractor.allocate
    extractor.instance_variable_set(:@concern_module_cache, {})
    extractor.define_singleton_method(:compute_app_concern_module) { |mod| LookupMemberOracle::CONCERNS.include?(mod.name) }
    extractor.send(:detect_included_concerns, klass)
  end

  def path_of(name)
    LookupMemberOracle.path_of(name)
  end

  # A unit as extraction publishes it, read back from JSON.
  def build_unit(identifier, type)
    klass = Object.const_get(identifier)
    path = path_of(identifier)
    original = LookupMemberOracle::FIXTURES.fetch(path)
    source = %w[model controller].include?(type) ? inlined(klass, type, original) : original
    locator = Woods::FileLines::Locator.new(source, Woods::SourceLineMap.build(original, source),
                                            identity_lines: Woods::SourceLineMap.identity_lines(original, source))
    metadata = { 'methods' => Woods::MethodTable.call(source).map { |entry| locator.annotate(entry) } }
    metadata['parent_class'] = klass.superclass.name if klass.is_a?(Class)
    JSON.parse(JSON.generate('identifier' => identifier, 'type' => type, 'file_path' => path,
                             'source_code' => source, 'metadata' => metadata, 'dependencies' => inheritance(klass)))
  end

  # The source with the concerns the extractor of +type+ inlines, by its own
  # block writer.
  def inlined(klass, type, original)
    model = type == 'model'
    modules = model ? model_modules(klass) : controller_modules(klass)
    return original if modules.empty?

    extractor = (model ? Woods::Extractors::ModelExtractor : Woods::Extractors::ControllerExtractor).allocate
    sources = modules.map { |mod| [mod.name, LookupMemberOracle::FIXTURES.fetch(path_of(mod.name))] }
    extractor.send(:insert_concern_block, klass, original, extractor.send(:build_concern_block, sources))
  end

  # The `:inheritance` edge extraction records to a published parent.
  def inheritance(klass)
    parent = klass.is_a?(Class) && LookupMemberOracle::UNITS.find { |(name, _)| name == klass.superclass.name }
    parent ? [{ 'type' => parent[1], 'target' => parent[0], 'via' => 'inheritance' }] : []
  end

  let(:units) { LookupMemberOracle::UNITS.to_h { |(identifier, type)| [identifier, build_unit(identifier, type)] } }
  let(:find_unit) { ->(identifier, _type = nil) { units[identifier] } }
  let(:concern_file) { ->(name) { path_of(name) } }

  def answer(identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    Woods::MCP::LookupMember.answer(units.fetch(reference.owner), reference,
                                    concern_file: concern_file, find_unit: find_unit)
  end

  # What Ruby does: nil when the owner does not respond, else the file and
  # line of the definition it calls and that method's visibility.
  def runtime(owner, separator, name)
    target = separator == '#' ? owner : owner.singleton_class
    return nil unless target.method_defined?(name) || target.private_method_defined?(name)

    file, line = target.instance_method(name).source_location
    visibility = if target.public_method_defined?(name) then 'public'
                 elsif target.protected_method_defined?(name) then 'protected'
                 else 'private'
                 end
    { 'file' => file, 'line' => line, 'visibility' => visibility }
  end

  # The definition a resolved answer names, as file and line.
  def named(data)
    file = data.dig('inherited_from', 'file_path') || data.dig('defined_in', 'file_path') ||
           data.dig('member_of', 'file_path')
    { 'file' => file, 'line' => data.dig('member', 'file_line'), 'visibility' => data.dig('member', 'visibility') }
  end

  def candidate_sites(data)
    data['candidates'].map do |candidate|
      file = candidate.dig('inherited_from', 'file_path') || candidate.dig('defined_in', 'file_path')
      { 'file' => file, 'line' => candidate.dig('member', 'file_line') }
    end
  end

  # One verdict per identifier: :exact, :stated (an explicit cannot-tell or a
  # caveat covers it), or a violation String.
  def verdict(identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    truth = runtime(Object.const_get(reference.owner), reference.separator, reference.name)
    data = answer(identifier)
    return unanswered_verdict(identifier, truth) unless data
    return "#{identifier}: answered #{named(data)}, Ruby does not respond" unless truth
    return candidates_verdict(identifier, data, truth) if data['candidates']
    return :exact if named(data) == truth
    return :stated if Array(data['caveats']).any?

    "#{identifier}: answered #{named(data)}, Ruby calls #{truth}"
  end

  # Not answered: right when Ruby does not respond, or calls a definition no
  # published unit holds.
  def unanswered_verdict(identifier, truth)
    hidden = path_of('LookupOracle::HiddenBase')
    return :exact unless truth && LookupMemberOracle::FIXTURES.key?(truth['file']) && truth['file'] != hidden

    "#{identifier}: not answered, Ruby calls #{truth}"
  end

  def candidates_verdict(identifier, data, truth)
    sites = candidate_sites(data)
    return :stated if sites.include?(truth.slice('file', 'line')) && data['statement'].include?('cannot tell')

    "#{identifier}: candidates #{sites} miss #{truth}"
  end

  it 'answers every fixture method as the runtime resolves it, or says it cannot tell' do
    identifiers = LookupMemberOracle::UNITS.flat_map { |(owner, _)| LookupMemberOracle::NAMES.flat_map { |name| ["#{owner}##{name}", "#{owner}.#{name}"] } }
    verdicts = identifiers.to_h { |identifier| [identifier, verdict(identifier)] }

    violations = verdicts.values.grep(String)
    expect(violations).to be_empty, "#{violations.size} answers disagree with Ruby:\n#{violations.join("\n")}"
    expect(identifiers.size).to eq(LookupMemberOracle::UNITS.size * LookupMemberOracle::NAMES.size * 2)
    # Only what the index cannot settle is left to a statement: a prepended
    # module it does not publish, a superclass it did not read, and a
    # controller's concerns, whose include order it does not record.
    expect(verdicts.select { |_, verdict| verdict == :stated }.keys).to contain_exactly(
      'LookupOracle::TracedRecord#trace_call', 'LookupOracle::OrphanRecord#tag_label',
      'LookupOracle::LeafController#shared_name', 'LookupOracle::LeafController.finder_for'
    )
  end

  describe 'the defects the oracle covers' do
    it 'does not answer a concern-level class_methods definition as a method of the concern (L1)' do
      expect(answer('LookupOracle::Stamping.stamp_all')).to be_nil
      expect(Woods::MCP::LookupMember.missing_sentence(Woods::MCP::LookupMember.parse('LookupOracle::Stamping.stamp_all'),
                                                       units['LookupOracle::Stamping']))
        .to include('a class method LookupOracle::Stamping gives to the classes that include it')
    end

    it "keeps a concern's own def self.x and instance methods (L1)" do
      expect(answer('LookupOracle::Stamping.stamp_registry')['member']).to include('kind' => 'singleton')
      expect(answer('LookupOracle::Stamping#stamp')['member']).to include('kind' => 'instance')
    end

    it 'answers a superclass override as inherited from that ancestor (L2)' do
      data = answer('LookupOracle::LeafRecord#link_target')

      expect(data['member_of']).to include('identifier' => 'LookupOracle::LeafRecord')
      expect(data['inherited_from']).to eq('identifier' => 'LookupOracle::MidRecord', 'type' => 'model',
                                           'file_path' => 'app/models/lookup_oracle/mid_record.rb')
      expect(data['statement']).to start_with('LookupOracle::LeafRecord#link_target is a public instance method ' \
                                              'that model unit LookupOracle::LeafRecord inherits from model unit ' \
                                              'LookupOracle::MidRecord, defined in its own body.')
      expect(data['source_code']).to eq("    def link_target\n      :mid\n    end\n")
      expect(data['other_definitions'].first).to include('file_unit' => 'LookupOracle::Linking')
    end

    it 'answers a method two levels up from the base body' do
      expect(answer('LookupOracle::LeafRecord#base_only')['inherited_from'])
        .to include('identifier' => 'LookupOracle::BaseRecord')
    end

    it "prefers the unit's own concern over a superclass body" do
      data = answer('LookupOracle::LeafRecord#stamp')

      expect(data['defined_in']).to include('identifier' => 'LookupOracle::Stamping')
      expect(data).not_to have_key('inherited_from')
    end

    it 'picks the last included concern where the order is published (L3, model)' do
      data = answer('LookupOracle::LeafRecord#shared_name')

      expect(data['defined_in']).to include('identifier' => 'LookupOracle::Grouping')
      expect(data['other_definitions'].map { |entry| entry['file_unit'] })
        .to eq(%w[LookupOracle::Sorting LookupOracle::Tagging])
      expect(data['statement']).to include('It overrides 2 other definitions of shared_name.')
    end

    it 'lists every candidate where the include order is not published (L3, controller)' do
      data = answer('LookupOracle::LeafController#shared_name')

      expect(data).not_to have_key('member')
      expect(data['candidates'].map { |candidate| candidate.dig('defined_in', 'identifier') })
        .to eq(%w[LookupOracle::Grouping LookupOracle::Sorting LookupOracle::Tagging])
      expect(data['statement']).to include('the index does not record the order').and include('cannot tell')
    end

    it 'answers a prepended concern over the own body (L4)' do
      data = answer('LookupOracle::PrependedRecord#save_record')

      expect(data['defined_in']).to include('identifier' => 'LookupOracle::Auditing', 'prepended' => true)
      expect(data['statement']).to include('which LookupOracle::PrependedRecord prepends')
      expect(answer('LookupOracle::PrependedRecord.build_record')['defined_in'])
        .to include('identifier' => 'LookupOracle::Auditing')
    end

    it 'ranks several prepended concerns as Ruby does: the last prepend call first, one call in written order' do
      expect(answer('LookupOracle::SealedRecord#seal')['defined_in']).to include('identifier' => 'LookupOracle::Sealing')
      expect(answer('LookupOracle::TwiceSealedRecord#seal')['defined_in'])
        .to include('identifier' => 'LookupOracle::Signing')
    end

    it 'states that a prepended module the index does not publish may override the answer (L4)' do
      data = answer('LookupOracle::TracedRecord#trace_call')

      expect(data['caveats']).to include(a_string_including('`prepend LookupOracleTracing`'))
    end

    it 'says the superclass chain was not fully read when the answer is a concern of an unread chain' do
      data = answer('LookupOracle::OrphanRecord#tag_label')

      expect(data['caveats']).to include(a_string_including('LookupOracle::HiddenBase is not a published unit'))
    end
  end
end
