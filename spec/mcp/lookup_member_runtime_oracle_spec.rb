# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'active_support'
require 'active_support/concern'
require 'active_support/core_ext/module/introspection'
require 'active_support/core_ext/module/delegation'
require 'forwardable'
require 'woods'
require 'woods/method_table'
require 'woods/file_lines'
require 'woods/source_line_map'
require 'woods/extractors/model_extractor'
require 'woods/extractors/controller_extractor'
require 'woods/extractors/job_extractor'
require 'woods/extractors/service_extractor'
require 'woods/mcp/lookup_member'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/plain_renderer'
require 'woods/mcp/renderers/markdown_renderer'

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
  'app/models/concerns/lookup_oracle/bundling.rb' => <<~RUBY,
    module LookupOracle
      module Bundling
        extend ActiveSupport::Concern
        include Sorting
      end
    end
  RUBY
  'app/models/lookup_oracle/abstract_base.rb' => <<~RUBY,
    module LookupOracle
      class AbstractBase
        include Linking

        def link_target
          :abstract
        end

        def tag_label
          :abstract
        end

        def shared_name
          :abstract
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/direct_record.rb' => <<~RUBY,
    module LookupOracle
      class DirectRecord < AbstractBase
        include Tagging
        include Bundling
      end
    end
  RUBY
  'app/models/concerns/lookup_oracle/wrapping.rb' => <<~RUBY,
    module LookupOracle
      module Wrapping
        def wrap_call
          :wrapping
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/wrap_base.rb' => <<~RUBY,
    module LookupOracle
      class WrapBase
        prepend Wrapping

        def wrap_call
          :wrap_base
        end
      end
    end
  RUBY
  'app/models/lookup_oracle/rewrapped_reader.rb' => <<~RUBY,
    module LookupOracle
      class RewrappedReader < WrapBase
        prepend Wrapping
        attr_reader :wrap_call, :wrap_label
      end
    end
  RUBY
  'app/models/lookup_oracle/rewrapped_record.rb' => <<~RUBY,
    module LookupOracle
      class RewrappedRecord < WrapBase
        prepend Wrapping

        def wrap_call
          :rewrapped
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
  'app/controllers/lookup_oracle/leaf_controller.rb' => <<~RUBY,
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
  'app/jobs/lookup_oracle/report_job.rb' => <<~RUBY,
    module LookupOracle
      class ReportJob
        def perform
          :outer
        end

        def self.queue_label
          :outer
        end

        def render_page
          :outer
        end

        class Preview < ReportJob
          def perform
            :preview
          end

          def self.queue_label
            :preview
          end

          class Draft < Preview
            def perform
              :draft
            end
          end
        end
      end
    end
  RUBY
  'app/services/lookup_oracle/macro_base.rb' => <<~RUBY,
    module LookupOracle
      class MacroBase
        def self.field(name)
          define_method(name) { :field }
        end

        def self.column(_name)
          nil
        end

        def self.before_action(*)
          nil
        end

        def self.validate(*)
          nil
        end

        def self.validates(*)
          nil
        end

        def self.helper_method(*)
          nil
        end

        def self.some_dsl(*names)
          names.each { |name| define_method(name) { :dsl } }
        end

        def self.build
          :base
        end

        def self.label
          :base
        end

        def perform
          :base
        end

        def label
          :base
        end

        def summary
          :base
        end

        def status
          :base
        end

        def total
          :base
        end

        def reader
          :base
        end

        def runner
          :base
        end

        def notify
          :base
        end

        def helper
          :base
        end

        def refresh
          :base
        end

        def archive
          :base
        end

        def prepare
          :base
        end

        def guarded
          :base
        end

        def score
          :base
        end

        def tally
          :base
        end

        def secret
          :base
        end

        def concealed
          :base
        end

        def hush
          :base
        end

        def self.quiet
          :base
        end

        def exposed
          :base
        end

        def checked
          :base
        end

        def secondary
          :base
        end

        def guardian
          :base
        end

        def second_item
          :base
        end

        def alpha_name
          :base
        end

        def beta_name
          :base
        end

        def relay
          :base
        end

        def whisper
          :base
        end

        def helper_relay_note
          :base
        end

        def helper_relay_tip
          :base
        end
      end
    end
  RUBY
  'app/services/lookup_oracle/macro_record.rb' => <<~RUBY,
    module LookupOracle
      class MacroRecord < MacroBase
        attr_reader :perform
        attr_writer :setter
        attr_accessor :total
        alias_method :label, :summary
        alias status summary
        define_method(:reader) { :own }
        delegate :runner, to: :helper
        delegate :notify, to: :helper, prefix: true
        field :refresh
        column :archive
        before_action :prepare
        validate :prepare
        attr_reader :score

        def score
          :own
        end

        def tally
          :own
        end

        alias_method :tally, :summary

        def compute
          send(:guarded)
        end

        class << self
          attr_reader :build
        end

        define_singleton_method(:label) { :own }

        private attr_reader :concealed

        private

        attr_reader :secret

        public

        attr_reader :hush
        private :hush

        class << self
          attr_reader :quiet
        end
        private_class_method :quiet
        helper_method :exposed
        validates :checked
        attr_reader :primary, :secondary
        protected

        attr_reader :guardian
        public

        delegate :first_item,
                 :second_item,
                 to: :helper
        some_dsl :alpha_name, :beta_name
        field :fresh_only
        column :ghost
        field :relay
        delegate :whisper, to: :helper, private: true

        private

        def muted
          :own
        end
        alias_method :muted_alias, :muted

        public

        private delegate :wrapped, to: :helper
        private alias_method :wrapped_alias, :summary
        DELEGATE_PREFIX = :helper
        HELPER_NAME = :helper
        delegate :relay_note, to: :helper, prefix: DELEGATE_PREFIX
        delegate :relay_tip, to: HELPER_NAME, prefix: true
      end
    end
  RUBY
  'app/services/lookup_oracle/macro_child.rb' => <<~RUBY,
    module LookupOracle
      class MacroChild < MacroRecord
        def total
          :child
        end
        column :relay
      end
    end
  RUBY
  'app/services/lookup_oracle/forwarded_record.rb' => <<~RUBY
    module LookupOracle
      class ForwardedRecord < MacroBase
        extend Forwardable

        def_delegator :@helper, :fetch, :perform
        def_delegators :@helper, :runner, :reader
      end
    end
  RUBY
}.freeze

# Macros whose method Ruby locates somewhere other than the call: an alias
# at the aliased method, a Forwardable delegator in its library.
LookupMemberOracle::LOCATED_ELSEWHERE = %w[alias alias_method def_delegator def_delegators].freeze

# Modules the extractors would treat as application concerns. The top-level
# tracing module is application code but not a concern, so it is not inlined.
LookupMemberOracle::CONCERNS = %w[
  Linking Stamping Tagging Sorting Grouping Auditing Signing Sealing Bundling Wrapping Helpers
].map { |name| "LookupOracle::#{name}" }.freeze

# [identifier, type]; HiddenBase and AbstractBase are deliberately not published (as an abstract
# `ApplicationRecord` is not).
LookupMemberOracle::UNITS = [
  %w[LookupOracle::BaseRecord model], %w[LookupOracle::MidRecord model], %w[LookupOracle::LeafRecord model],
  %w[LookupOracle::PrependedRecord model], %w[LookupOracle::TracedRecord model],
  %w[LookupOracle::OrphanRecord model], %w[LookupOracle::SealedRecord model],
  %w[LookupOracle::CoSealedRecord model], %w[LookupOracle::TwiceSealedRecord model],
  %w[LookupOracle::DirectRecord model], %w[LookupOracle::WrapBase model], %w[LookupOracle::RewrappedRecord model],
  %w[LookupOracle::RewrappedReader model],
  %w[LookupOracle::BaseController controller], %w[LookupOracle::MidController controller],
  %w[LookupOracle::LeafController controller],
  %w[LookupOracle::Stamping concern], %w[LookupOracle::Tagging concern], %w[LookupOracle::Grouping concern],
  %w[LookupOracle::Helpers lib],
  %w[LookupOracle::ReportJob job], %w[LookupOracle::ReportJob::Preview job],
  %w[LookupOracle::ReportJob::Preview::Draft job],
  %w[LookupOracle::MacroBase service], %w[LookupOracle::MacroRecord service], %w[LookupOracle::MacroChild service],
  %w[LookupOracle::ForwardedRecord service]
].freeze

# Every method name the fixtures define, asked of every unit as `#` and `.`,
# with the names only a macro defines.
LookupMemberOracle::NAMES = LookupMemberOracle::FIXTURES.values.flat_map do |source|
  source.scan(/def (?:self\.)?(\w+)/).flatten
end.push('setter=', 'total=', 'helper_notify', 'fresh_only', 'ghost', 'wrapped', 'wrapped_alias').uniq.freeze

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
    source = case type
             when 'model', 'controller' then inlined(klass, type, original)
             when 'job' then job_source(identifier, original)
             when 'service' then service_source(identifier, original)
             else original
             end
    map = Woods::SourceLineMap.build(original, source)
    locator = Woods::FileLines::Locator.new(source, map,
                                            identity_lines: Woods::SourceLineMap.identity_lines(original, source))
    metadata = { 'methods' => Woods::MethodTable.call(source).map { |entry| locator.annotate(entry) } }
    metadata['source_line_map'] = map if map
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

  # A service's source under the service extractor's banner.
  def service_source(identifier, original)
    Woods::Extractors::ServiceExtractor.allocate.send(:annotate_source, original, identifier)
  end

  # A job's source as the job extractor publishes it: a class nested in
  # another class's body is its own lexical range, under the job banner.
  def job_source(identifier, original)
    extractor = Woods::Extractors::JobExtractor.allocate
    extractor.send(:annotate_source, extractor.send(:lexical_source, original, identifier), identifier)
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

  # The definition a resolved answer names, as file and line. A unit
  # published as a slice of its file has no mapped file lines; its definition
  # is then placed where its published text occurs in the file, once.
  def named(data)
    file = data.dig('inherited_from', 'file_path') || data.dig('defined_in', 'file_path') ||
           data.dig('member_of', 'file_path')
    line = data.dig('member', 'file_line') || placed(file, data['source_code'])
    { 'file' => file, 'line' => line, 'visibility' => data.dig('member', 'visibility') }
  end

  def placed(file, text)
    lines = LookupMemberOracle::FIXTURES.fetch(file, '').lines
    wanted = text.to_s.lines
    starts = (0..(lines.size - wanted.size)).select { |index| lines[index, wanted.size] == wanted }
    starts.first + 1 if starts.size == 1 && !wanted.empty?
  end

  def candidate_sites(data)
    data['candidates'].map do |candidate|
      file = candidate.dig('inherited_from', 'file_path') || candidate.dig('defined_in', 'file_path') ||
             data.dig('member_of', 'file_path')
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
    return macro_verdict(identifier, reference, data, truth) if data.dig('member', 'defined_by')
    return candidates_verdict(identifier, reference, data, truth) if data['candidates']
    return "#{identifier}: answered #{named(data)}, Ruby does not respond" unless truth
    return :exact if named(data) == truth
    return :stated if Array(data['caveats']).any?

    "#{identifier}: answered #{named(data)}, Ruby calls #{truth}"
  end

  # A macro answer: a stated cannot-tell, or the macro of the level whose
  # class (or singleton class) Ruby reports as the method's owner, at the
  # line Ruby reports where that is the call, with its visibility where the
  # answer states one.
  def macro_verdict(identifier, reference, data, truth)
    return "#{identifier}: answered #{named(data)}, Ruby does not respond" unless truth

    wrong_owner = owner_violation(identifier, reference, data)
    return wrong_owner if wrong_owner

    wrong_visibility = visibility_violation(identifier, data, truth)
    return wrong_visibility if wrong_visibility
    return :exact if LookupMemberOracle::LOCATED_ELSEWHERE.include?(data.dig('member', 'defined_by'))

    site = named(data)
    site.delete('visibility') unless data['member'].key?('visibility')
    site == truth.slice(*site.keys) ? :exact : "#{identifier}: answered #{site}, Ruby calls #{truth}"
  end

  # A violation String when the answer states a visibility Ruby does not give.
  def visibility_violation(identifier, data, truth)
    visibility = data.dig('member', 'visibility')
    return if visibility.nil? || visibility == truth['visibility']

    "#{identifier}: answered #{visibility}, Ruby's is #{truth['visibility']}"
  end

  # A cannot-tell answer whose first candidate is a call Woods does not know.
  def possible_macro?(data)
    data['candidates']&.first&.dig('member', 'defined_by')
  end

  # Right when it says it cannot tell and Ruby does not respond (the call
  # only may define it), calls one of the candidates, or calls a method the
  # macro's level owns (the call defined it).
  def possible_macro_verdict(identifier, reference, data, truth)
    return "#{identifier}: a macro candidate without cannot tell" unless data['statement'].include?('cannot tell')
    return :stated if truth.nil? || candidate_sites(data).include?(truth.slice('file', 'line'))

    macros = data['candidates'].select { |candidate| candidate.dig('member', 'defined_by') }
    return :stated if macros.any? do |macro|
      !owner_violation(identifier, reference, data.merge('inherited_from' => macro['inherited_from']))
    end

    "#{identifier}: candidates #{candidate_sites(data)} miss #{truth}"
  end

  # A violation String unless Ruby's owner of the method is the answer's
  # level (its singleton class for a class method).
  def owner_violation(identifier, reference, data)
    owner = Object.const_get(reference.owner)
    level = Object.const_get(data.dig('inherited_from', 'identifier') || reference.owner)
    target, expected = reference.separator == '#' ? [owner, level] : [owner.singleton_class, level.singleton_class]
    actual = target.instance_method(reference.name).owner
    "#{identifier}: answered #{level}, Ruby's owner is #{actual}" unless actual == expected
  end

  def published_line(identifier, text)
    units.fetch(identifier)['source_code'].lines.index { |line| line.include?(text) } + 1
  end

  # The sentence a not-found answer adds for an owner that is published.
  def missing(identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    Woods::MCP::LookupMember.missing_sentence(reference, units.fetch(reference.owner), find_unit: find_unit)
  end

  # Not answered: right when Ruby does not respond, or calls a definition no
  # published unit holds.
  def unanswered_verdict(identifier, truth)
    hidden = %w[LookupOracle::HiddenBase LookupOracle::AbstractBase].map { |name| path_of(name) }
    return :exact unless truth && LookupMemberOracle::FIXTURES.key?(truth['file']) && !hidden.include?(truth['file'])
    return :stated if missing(identifier).include?('names it and may define it')

    "#{identifier}: not answered, Ruby calls #{truth}"
  end

  def candidates_verdict(identifier, reference, data, truth)
    return possible_macro_verdict(identifier, reference, data, truth) if possible_macro?(data)
    return "#{identifier}: candidates #{candidate_sites(data)}, Ruby does not respond" unless truth

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
    # module it does not publish, a superclass it did not read, a
    # controller's concerns, whose include order it does not record, a
    # macro it does not know in front of another definition, and a macro
    # that alone may define the name, named in the not-found answer.
    expect(verdicts.select { |_, verdict| verdict == :stated }.keys).to contain_exactly(
      'LookupOracle::TracedRecord#trace_call', 'LookupOracle::OrphanRecord#tag_label',
      'LookupOracle::DirectRecord#link_target',
      'LookupOracle::LeafController#shared_name', 'LookupOracle::LeafController.finder_for',
      *%w[MacroRecord MacroChild].product(%w[refresh archive alpha_name beta_name relay helper_relay_note
                                             helper_relay_tip])
                                 .map { |owner, name| "LookupOracle::#{owner}##{name}" },
      *%w[MacroRecord MacroChild].map { |owner| "LookupOracle::#{owner}#fresh_only" }
    )
  end

  it 'states a caveat only where the published source cannot place the answer' do
    identifiers = LookupMemberOracle::UNITS.flat_map do |(owner, _)|
      LookupMemberOracle::NAMES.flat_map { |name| ["#{owner}##{name}", "#{owner}.#{name}"] }
    end

    # A prepend of a module the index does not publish (every TracedRecord
    # answer), a concern that reaches the unit only through an unread
    # superclass (OrphanRecord's Tagging, DirectRecord's Linking). A macro
    # Woods does not know lists what it may override as candidates instead.
    expect(identifiers.select { |identifier| answer(identifier)&.key?('caveats') }).to contain_exactly(
      'LookupOracle::TracedRecord#tag_label', 'LookupOracle::TracedRecord#shared_name',
      'LookupOracle::TracedRecord.finder_for', 'LookupOracle::TracedRecord#trace_call',
      'LookupOracle::OrphanRecord#tag_label', 'LookupOracle::OrphanRecord#shared_name',
      'LookupOracle::OrphanRecord.finder_for',
      'LookupOracle::DirectRecord#link_target', 'LookupOracle::DirectRecord.link_scope'
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

    it 'needs no caveat for a concern the unit itself includes, under an unpublished parent' do
      data = answer('LookupOracle::DirectRecord#tag_label')

      expect(data['defined_in']).to include('identifier' => 'LookupOracle::Tagging')
      expect(data).not_to have_key('caveats')
    end

    it 'places a concern an included concern depends on at the level that includes it' do
      data = answer('LookupOracle::DirectRecord#shared_name')

      expect(data['defined_in']).to include('identifier' => 'LookupOracle::Sorting')
      expect(data).not_to have_key('caveats')
    end

    it 'says why when the concern reaches the unit only through the unpublished parent' do
      expect(answer('LookupOracle::DirectRecord#link_target')['caveats']).to eq(
        ['No unit Woods read (LookupOracle::DirectRecord) includes LookupOracle::Linking in its own body, so ' \
         'LookupOracle::DirectRecord includes it through a superclass Woods did not read (its parent ' \
         'LookupOracle::AbstractBase is not a published unit); that superclass\'s own definition of link_target ' \
         'could come first.']
      )
    end

    it 'puts a re-prepended plain module before an attr_reader of the same name, and reads the macro otherwise' do
      data = answer('LookupOracle::RewrappedReader#wrap_call')

      expect(data['defined_in']).to include('identifier' => 'LookupOracle::Wrapping', 'prepended' => true)
      expect(data['other_definitions']).to include(include('defined_by' => 'attr_reader', 'file_line' => 4))
      expect(answer('LookupOracle::RewrappedReader#wrap_label')['member']).to include('defined_by' => 'attr_reader')
    end

    it 'prepends a plain module again where a subclass prepends it, but not a concern' do
      expect(answer('LookupOracle::RewrappedRecord#wrap_call')['defined_in'])
        .to include('identifier' => 'LookupOracle::Wrapping', 'prepended' => true)
      expect(answer('LookupOracle::CoSealedRecord#seal')).not_to have_key('caveats')
    end
  end

  # A class nested in the body of its own superclass is published as its
  # own lexical range, where its declaration reads `class Preview`, not the
  # identifier.
  describe 'a class nested inside its own superclass (N1)' do
    it 'publishes the nested class as its own slice, as the job extractor does' do
      source = units['LookupOracle::ReportJob::Preview']['source_code']

      expect(source).to include('class Preview < ReportJob').and include(':draft')
      expect(source).not_to include(':outer')
    end

    it "answers the nested class's own instance and class methods from its own body" do
      instance = answer('LookupOracle::ReportJob::Preview#perform')
      singleton = answer('LookupOracle::ReportJob::Preview.queue_label')

      expect(instance).not_to have_key('inherited_from')
      expect(instance['source_code']).to eq("      def perform\n        :preview\n      end\n")
      expect(instance['other_definitions'].map { |entry| entry['unit'] }).to eq(%w[LookupOracle::ReportJob])
      expect(singleton).not_to have_key('inherited_from')
      expect(singleton['member']).to include('kind' => 'singleton')
      expect(singleton['source_code']).to include(':preview')
    end

    it 'reports no file line for a definition in a slice, which carries no source_line_map' do
      expect(answer('LookupOracle::ReportJob::Preview#perform')['member']).to include('file_line' => nil)
    end

    it 'answers a class nested two levels down from its own body' do
      data = answer('LookupOracle::ReportJob::Preview::Draft#perform')

      expect(data).not_to have_key('inherited_from')
      expect(data['source_code']).to include(':draft')
      expect(data['other_definitions'].map { |entry| entry['unit'] })
        .to eq(%w[LookupOracle::ReportJob::Preview LookupOracle::ReportJob])
    end

    it 'answers a name the nested class does not define as inherited from the nearest level that does' do
      expect(answer('LookupOracle::ReportJob::Preview::Draft.queue_label')['inherited_from'])
        .to include('identifier' => 'LookupOracle::ReportJob::Preview')
      expect(answer('LookupOracle::ReportJob::Preview#render_page')['inherited_from'])
        .to include('identifier' => 'LookupOracle::ReportJob')
    end

    it 'keeps answering the enclosing class from its own definitions, not the nested ones' do
      data = answer('LookupOracle::ReportJob#perform')

      expect(data['member']).to include('owner' => 'LookupOracle::ReportJob', 'file_line' => 3)
      expect(data).not_to have_key('other_definitions')
    end
  end

  # A class body can define the name by a macro the method table cannot
  # see. The level that does so is the answer, or, for a macro Woods does
  # not know, the level that may; a superclass `def` is never presented as
  # what runs past it.
  describe 'a name defined by a class-body macro (N2)' do
    {
      'LookupOracle::MacroRecord#perform' => ['attr_reader', 3],
      'LookupOracle::MacroRecord#setter=' => ['attr_writer', 4],
      'LookupOracle::MacroRecord#total' => ['attr_accessor', 5],
      'LookupOracle::MacroRecord#total=' => ['attr_accessor', 5],
      'LookupOracle::MacroRecord#label' => ['alias_method', 6],
      'LookupOracle::MacroRecord#status' => ['alias', 7],
      'LookupOracle::MacroRecord#reader' => ['define_method', 8],
      'LookupOracle::MacroRecord#runner' => ['delegate', 9],
      'LookupOracle::MacroRecord#helper_notify' => ['delegate', 10],
      'LookupOracle::MacroRecord.build' => ['attr_reader', 32],
      'LookupOracle::MacroRecord.label' => ['define_singleton_method', 35],
      'LookupOracle::ForwardedRecord#perform' => ['def_delegator', 5],
      'LookupOracle::ForwardedRecord#runner' => ['def_delegators', 6],
      'LookupOracle::MacroRecord#secondary' => ['attr_reader', 54],
      'LookupOracle::MacroRecord#guardian' => ['attr_reader', 57],
      'LookupOracle::MacroRecord#second_item' => ['delegate', 60]
    }.each do |identifier, (macro, line)|
      it "answers #{identifier} as defined in its own body by #{macro}" do
        data = answer(identifier)

        expect(data['member']).to include('defined_by' => macro, 'file_line' => line)
        expect(data).not_to have_key('inherited_from')
        expect(data['statement']).to include("by `#{macro}`").and include('in its own body')
        expect(data['statement']).not_to include('cannot tell')
      end
    end

    it 'lists the superclass def a known macro overrides, with the call as the source' do
      data = answer('LookupOracle::MacroRecord#perform')

      expect(data['source_code']).to eq("    attr_reader :perform\n")
      expect(data['other_definitions']).to contain_exactly(include('unit' => 'LookupOracle::MacroBase'))
    end

    it 'names the aliased method of an alias' do
      expect(answer('LookupOracle::MacroRecord#label')['member']).to include('alias_of' => 'summary')
      expect(answer('LookupOracle::MacroRecord#status')['member']).to include('alias_of' => 'summary')
    end

    it 'answers a macro of a superclass level as inherited, below a nearer def' do
      inherited = answer('LookupOracle::MacroChild#perform')

      expect(inherited['inherited_from']).to include('identifier' => 'LookupOracle::MacroRecord')
      expect(inherited['member']).to include('defined_by' => 'attr_reader', 'file_line' => 3)
      expect(answer('LookupOracle::MacroChild#total')['member']).not_to have_key('defined_by')
    end

    it 'answers whichever of a def and a known macro in one body comes later' do
      expect(answer('LookupOracle::MacroRecord#score')['member']).to include('file_line' => 17)
      expect(answer('LookupOracle::MacroRecord#score')['member']).not_to have_key('defined_by')
      expect(answer('LookupOracle::MacroRecord#tally')['member'])
        .to include('defined_by' => 'alias_method', 'file_line' => 25)
    end

    it 'reads the visibility of attr_reader from `private attr_reader` and from a bare private' do
      expect(answer('LookupOracle::MacroRecord#concealed')['member']).to include('visibility' => 'private')
      expect(answer('LookupOracle::MacroRecord#secret')['member']).to include('visibility' => 'private')
      expect(answer('LookupOracle::MacroRecord#perform')['member']).to include('visibility' => 'public')
    end

    it 'reads a later `private :name` or `private_class_method :name` into the visibility of a macro' do
      %w[LookupOracle::MacroRecord#hush LookupOracle::MacroRecord.quiet].each do |identifier|
        expect(answer(identifier)['member']).to include('defined_by' => 'attr_reader', 'visibility' => 'private')
      end
    end

    it 'says it cannot tell for a macro it does not know, without presenting the superclass def as the answer' do
      %w[LookupOracle::MacroRecord#refresh LookupOracle::MacroRecord#archive].each do |identifier|
        data = answer(identifier)
        macro, fallback, *rest = data['candidates']

        expect(data.keys).not_to include('member', 'source_code', 'other_definitions', 'caveats')
        expect(macro['member']).to include('defined_by' => a_string_matching(/\A(field|column)\z/))
        expect(macro['note']).to start_with("may define #{identifier[/\w+\z/]}")
        expect(macro).not_to include('inherited_from', 'defined_in')
        expect(macro['source_code']).to match(/\A    (field|column) :/)
        expect(fallback).to include('inherited_from' => include('identifier' => 'LookupOracle::MacroBase'))
        expect(rest).to be_empty
        expect(data['statement']).to include('may define').and include('cannot tell')
      end
    end

    it 'labels each cannot-tell candidate with the unit that holds it in the text renderers' do
      data = answer('LookupOracle::MacroRecord#refresh')
      plain = Woods::MCP::Renderers::PlainRenderer.new.render(:lookup_member, data)
      markdown = Woods::MCP::Renderers::MarkdownRenderer.new.render(:lookup_member, data)

      expect(plain).to include('Candidate 1: LookupOracle::MacroRecord (may define refresh')
        .and include('Candidate 2: LookupOracle::MacroBase')
      expect(markdown).to include('### Candidate 1: LookupOracle::MacroRecord (may define refresh')
        .and include('### Candidate 2: LookupOracle::MacroBase')
    end

    it 'reads attr_reader under a bare protected as protected' do
      expect(answer('LookupOracle::MacroRecord#guardian')['member']).to include('visibility' => 'protected')
    end

    it 'answers a multi-line delegate from the whole call' do
      data = answer('LookupOracle::MacroRecord#second_item')

      expect(data['member']).to include('line' => data['member']['end_line'] - 2)
      expect(data['source_code']).to include(':second_item,').and include('to: :helper')
    end

    it 'stops at an unknown macro for every literal it carries, and says it cannot tell' do
      %w[alpha_name beta_name].each do |name|
        data = answer("LookupOracle::MacroRecord##{name}")

        expect(data.keys).not_to include('member', 'other_definitions')
        expect(data['candidates'].first['member']).to include('defined_by' => 'some_dsl', 'file_line' => 63)
        expect(data['statement']).to include('may define').and include('cannot tell')
      end
    end

    it 'says it cannot tell through a superclass level whose macro it does not know' do
      data = answer('LookupOracle::MacroChild#refresh')

      expect(data['candidates'].first['inherited_from']).to include('identifier' => 'LookupOracle::MacroRecord')
      expect(data['statement']).to include('cannot tell')
    end

    it 'does not take a name a macro only refers to as a definition of it' do
      %w[prepare guarded summary helper notify exposed checked].each do |name|
        expect(answer("LookupOracle::MacroRecord##{name}")['inherited_from'])
          .to include('identifier' => 'LookupOracle::MacroBase'), name
      end
    end

    it 'answers not found, naming the macro, when nothing else on that side defines the name' do
      expect(answer('LookupOracle::MacroRecord.refresh')).to be_nil
      expect(answer('LookupOracle::MacroRecord#ghost')).to be_nil
      expect(missing('LookupOracle::MacroRecord#ghost'))
        .to end_with("`column` at line #{published_line('LookupOracle::MacroRecord', 'column :ghost')} of the " \
                     'published source of LookupOracle::MacroRecord names it and may define it.')
      expect(missing('LookupOracle::MacroChild#fresh_only'))
        .to include("`field` at line #{published_line('LookupOracle::MacroRecord', 'field :fresh_only')} of the " \
                    'published source of LookupOracle::MacroRecord names it')
    end

    it 'lists every definition past the macro, further macros included, nearest first' do
      data = answer('LookupOracle::MacroChild#relay')

      expect(data['candidates'].map { |candidate| candidate.dig('member', 'defined_by') })
        .to eq(['column', 'field', nil])
      expect(data['candidates'].map { |candidate| candidate.dig('inherited_from', 'identifier') })
        .to eq([nil, 'LookupOracle::MacroRecord', 'LookupOracle::MacroBase'])
    end

    it 'says an instance method with the right article when Ruby fixes no visibility Woods reads' do
      expect(answer('LookupOracle::ForwardedRecord#perform')['statement'])
        .to start_with('LookupOracle::ForwardedRecord#perform is an instance method of')
    end

    it 'states the visibility delegate and alias_method give' do
      expect(answer('LookupOracle::MacroRecord#runner')['member']).to include('visibility' => 'public')
      expect(answer('LookupOracle::MacroRecord#whisper')['member']).to include('visibility' => 'private')
      expect(answer('LookupOracle::MacroRecord#muted_alias')['member']).to include('visibility' => 'private')
      expect(answer('LookupOracle::MacroRecord#label')['member']).not_to have_key('visibility')
    end

    it 'states the same visibility for a known macro a subclass inherits, as Ruby gives it' do
      { 'runner' => 'public', 'whisper' => 'private', 'secret' => 'private' }.each do |name, visibility|
        data = answer("LookupOracle::MacroChild##{name}")
        target = LookupOracle::MacroChild

        expect(data['inherited_from']).to include('identifier' => 'LookupOracle::MacroRecord'), name
        expect(data['member']).to include('visibility' => visibility), name
        expect(target.private_method_defined?(name)).to eq(visibility == 'private'), name
        expect(data['statement']).to include("is a #{visibility} instance method"), name
      end
    end

    it 'states private for a delegate or alias_method passed to private, as Ruby gives it' do
      %w[wrapped wrapped_alias].each do |name|
        expect(LookupOracle::MacroRecord.private_method_defined?(name)).to be(true), name
        expect(answer("LookupOracle::MacroRecord##{name}")['member']).to include('visibility' => 'private'), name
        expect(answer("LookupOracle::MacroChild##{name}")['member']).to include('visibility' => 'private'), name
      end
    end

    # The prefix is not a literal (a constant, or `true` with a `to:` that is
    # not one), so the call may define any name ending in `_relay_note`.
    it 'cannot tell past a delegate whose prefix is not a literal, as Ruby calls the delegate' do
      %w[helper_relay_note helper_relay_tip].each do |name|
        data = answer("LookupOracle::MacroRecord##{name}")

        expect(LookupOracle::MacroRecord.instance_method(name).owner).to eq(LookupOracle::MacroRecord)
        expect(data['statement']).to include('cannot tell'), name
        expect(data['candidates'].map { |candidate| candidate.dig('member', 'defined_by') }).to eq(['delegate', nil])
      end
    end

    it 'keeps a plain-body instance macro off the class side' do
      expect(answer('LookupOracle::MacroRecord.perform')).to be_nil
      expect(answer('LookupOracle::MacroRecord#build')).to be_nil
    end
  end
end
