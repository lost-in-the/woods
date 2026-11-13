# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/method_table'
require 'woods/file_lines'
require 'woods/source_line_map'
require 'woods/mcp/lookup_member'

# Fixture models and controllers for the Rails macro side of `lookup` member
# answers. Each base class defines the names its subclass's macros carry, so
# a macro read on the wrong side, or not at all, gives a wrong answer.
module RailsMacroOracle
  def self.path_of(name)
    declaration = /(?:module|class) #{name.split('::').last}\b/
    RailsMacroOracle::FIXTURES.find { |_, source| source.match?(declaration) }&.first
  end
end

RailsMacroOracle::FIXTURES = {
  'app/models/concerns/rails_macro_oracle/ownable.rb' => <<~RUBY,
    module RailsMacroOracle
      module Ownable
        extend ActiveSupport::Concern

        def keeper
          :concern
        end
      end
    end
  RUBY
  'app/models/rails_macro_oracle/base_record.rb' => <<~RUBY,
    module RailsMacroOracle
      class BaseRecord < ActiveRecord::Base
        self.abstract_class = true

        scope :flagged, lambda {
          where(title: 'flagged')
        }

        def flagged
          :base
        end

        def self.notes
          :base
        end

        def self.score
          :base
        end

        def notes
          :base
        end

        def recent
          :base
        end

        def nickname
          :base
        end

        def theme
          :base
        end

        def config_flag
          :base
        end

        def secret_score
          :base
        end
      end
    end
  RUBY
  'app/models/rails_macro_oracle/widget.rb' => <<~RUBY,
    module RailsMacroOracle
      class Widget < BaseRecord
        include Ownable

        self.table_name = 'oracle_widgets'
        has_many :notes, class_name: 'RailsMacroOracle::Widget', foreign_key: :keeper_id
        belongs_to :keeper, class_name: 'RailsMacroOracle::Widget', optional: true
        has_one :badge, class_name: 'RailsMacroOracle::Widget', foreign_key: :keeper_id
        has_and_belongs_to_many :tags, class_name: 'RailsMacroOracle::Widget', join_table: 'oracle_tags',
                                       association_foreign_key: :tag_id
        attribute :score, :integer
        alias_attribute :nickname, :title
        store_accessor :settings, :theme, :color
        store_accessor :settings, :tone, prefix: true
        store_accessor :settings, :shade, suffix: :pref
        store_accessor :settings, :hue, prefix: 'paint'
        GLOW_PREFIX = :lamp
        store_accessor :settings, :glow, prefix: GLOW_PREFIX
        class_attribute :alpha_flag, :beta_flag
        scope :recent, -> { all }
        class_attribute :config_flag
        class_attribute :quiet_flag, instance_accessor: false
        serialize :prefs
        has_secure_token :token

        private

        attribute :secret_score, :integer
        attribute :hidden_score, :integer
        has_many :hidden_notes, class_name: 'RailsMacroOracle::Widget', foreign_key: :keeper_id
        belongs_to :hidden_keeper, class_name: 'RailsMacroOracle::Widget', optional: true, foreign_key: :keeper_id
        alias_attribute :hidden_alias, :title
        store_accessor :settings, :hidden_theme
        scope :hidden_recent, -> { all }
        class_attribute :hidden_flag

        public

        scope :sealed, -> { all }
        private_class_method :sealed
      end
    end
  RUBY
  'app/models/rails_macro_oracle/gadget.rb' => <<~RUBY,
    module RailsMacroOracle
      class Gadget < Widget
      end
    end
  RUBY
  'app/controllers/rails_macro_oracle/base_panel_controller.rb' => <<~RUBY,
    module RailsMacroOracle
      class BasePanelController < ActionController::Base
        def pick_layout
          'base'
        end

        def recover
          :base
        end

        def rails_oracle_panel
          :base
        end
      end
    end
  RUBY
  'app/controllers/rails_macro_oracle/panel_controller.rb' => <<~RUBY
    module RailsMacroOracle
      class PanelController < BasePanelController
        layout :pick_layout
        helper :rails_oracle_panel
        rescue_from StandardError, with: :recover
      end
    end
  RUBY
}.freeze

RailsMacroOracle::CONCERNS = %w[RailsMacroOracle::Ownable].freeze

# [identifier, type]
RailsMacroOracle::UNITS = [%w[RailsMacroOracle::BaseRecord model], %w[RailsMacroOracle::Widget model],
                           %w[RailsMacroOracle::Gadget model],
                           %w[RailsMacroOracle::Ownable concern], %w[RailsMacroOracle::BasePanelController controller],
                           %w[RailsMacroOracle::PanelController controller]].freeze

# The per-side behaviour of common Rails macros in `lookup` member answers,
# compared with a booted ActiveRecord and ActionController: a macro that
# defines the name is the answer at its level, ranked where Ruby ranks the
# module it defines into; one that defines only the other side, or only
# refers to a method, does not stop the walk.
RSpec.describe 'MCP lookup member answers for Rails macros', :booted_app do
  before(:context) do
    require 'active_record'
    require 'action_controller'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:oracle_widgets) do |table|
        table.string :title
        table.text :settings
        table.text :prefs
        table.string :token
        table.integer :keeper_id
      end
      create_table(:oracle_tags, id: false) do |table|
        table.integer :widget_id
        table.integer :tag_id
      end
    end
    # `helper :name` loads `<name>_helper.rb` by file on Rails 6.0 and by constant from 6.1 on.
    @helper_dir = Dir.mktmpdir('rails_oracle_helpers')
    File.write(File.join(@helper_dir, 'rails_oracle_panel_helper.rb'), "module RailsOraclePanelHelper\nend\n")
    $LOAD_PATH.unshift(@helper_dir)
    require 'rails_oracle_panel_helper'
    RailsMacroOracle::FIXTURES.each { |path, source| TOPLEVEL_BINDING.eval(source, path, 1) }
    RailsMacroOracle::Widget.define_attribute_methods
    RailsMacroOracle::Gadget.define_attribute_methods
  end

  after(:context) do
    %i[Ownable BaseRecord Widget Gadget BasePanelController PanelController].each do |name|
      RailsMacroOracle.send(:remove_const, name) if RailsMacroOracle.const_defined?(name, false)
    end
    Object.send(:remove_const, :RailsOraclePanelHelper)
    $LOAD_PATH.delete(@helper_dir)
    $LOADED_FEATURES.delete(File.join(@helper_dir, 'rails_oracle_panel_helper.rb'))
    FileUtils.remove_entry(@helper_dir)
    ActiveRecord::Base.remove_connection
  end

  before { stub_const('Rails', Module.new.tap { |rails| rails.define_singleton_method(:root) { Pathname('/app') } }) }

  # The model extractor's own concern order and inlining, kept to the
  # fixture concerns (its application check is stubbed to answer yes).
  def inlined(klass, original)
    extractor = Woods::Extractors::ModelExtractor.allocate
    extractor.define_singleton_method(:app_source?) { |*| true }
    extractor.define_singleton_method(:defined_in_app?) { |mod| RailsMacroOracle::CONCERNS.include?(mod.name) }
    modules = extractor.send(:extract_included_modules, klass).select do |mod|
      RailsMacroOracle::CONCERNS.include?(mod.name)
    end
    return original if modules.empty?

    sources = modules.map { |mod| [mod.name, RailsMacroOracle::FIXTURES.fetch(RailsMacroOracle.path_of(mod.name))] }
    extractor.send(:insert_concern_block, klass, original, extractor.send(:build_concern_block, sources))
  end

  def build_unit(identifier, type)
    require 'woods/extractors/model_extractor'
    klass = Object.const_get(identifier)
    path = RailsMacroOracle.path_of(identifier)
    original = RailsMacroOracle::FIXTURES.fetch(path)
    source = type == 'model' ? inlined(klass, original) : original
    JSON.parse(JSON.generate('identifier' => identifier, 'type' => type, 'file_path' => path,
                             'source_code' => source, 'metadata' => metadata(klass, original, source),
                             'dependencies' => inheritance(klass)))
  end

  # The method table and line map extraction publishes, and the parent.
  def metadata(klass, original, source)
    map = Woods::SourceLineMap.build(original, source)
    locator = Woods::FileLines::Locator.new(source, map,
                                            identity_lines: Woods::SourceLineMap.identity_lines(original, source))
    metadata = { 'methods' => Woods::MethodTable.call(source).map { |entry| locator.annotate(entry) } }
    metadata['source_line_map'] = map if map
    metadata['parent_class'] = klass.superclass.name if klass.is_a?(Class)
    metadata
  end

  def inheritance(klass)
    parent = klass.is_a?(Class) && RailsMacroOracle::UNITS.find { |(name, _)| name == klass.superclass.name }
    parent ? [{ 'type' => parent[1], 'target' => parent[0], 'via' => 'inheritance' }] : []
  end

  let(:units) { RailsMacroOracle::UNITS.to_h { |(identifier, type)| [identifier, build_unit(identifier, type)] } }
  let(:find_unit) { ->(identifier, _type = nil) { units[identifier] } }

  def answer(identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    Woods::MCP::LookupMember.answer(units.fetch(reference.owner), reference, find_unit: find_unit)
  end

  def missing(identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    Woods::MCP::LookupMember.missing_sentence(reference, units.fetch(reference.owner), find_unit: find_unit)
  end

  # The method Ruby calls, or nil when the owner does not respond.
  def runtime(identifier)
    reference = Woods::MCP::LookupMember.parse(identifier)
    owner = Object.const_get(reference.owner)
    target = reference.separator == '#' ? owner : owner.singleton_class
    name = reference.name
    return nil unless target.method_defined?(name) || target.private_method_defined?(name)

    visibility = if target.public_method_defined?(name) then 'public'
                 elsif target.protected_method_defined?(name) then 'protected'
                 else 'private'
                 end
    { method: target.instance_method(name), visibility: visibility }
  end

  # Active Record generates an inherited `attribute`'s methods again in the
  # subclass's own module, unless an application class already defines the
  # name: the declaration is the superclass's, the module the owner's.
  def regenerated?(identifier, macro, truth)
    macro == 'attribute' &&
      owned_at?(truth[:method].owner, Object.const_get(Woods::MCP::LookupMember.parse(identifier).owner))
  end

  # Whether +owner+ (a method's owner) belongs to +level+: the class itself,
  # its singleton class, or a module the class includes itself (a generated
  # attribute, association or store module), not one a superclass includes.
  def owned_at?(owner, level)
    return true if owner == level || owner == level.singleton_class

    own = level.ancestors.take_while { |ancestor| ancestor != level.superclass }
    own.include?(owner) && !RailsMacroOracle::CONCERNS.include?(owner.name)
  end

  {
    'RailsMacroOracle::Widget#notes' => ['has_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#notes=' => ['has_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#keeper=' => ['belongs_to', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#badge' => ['has_one', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#badge=' => ['has_one', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#tags' => ['has_and_belongs_to_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#tags=' => ['has_and_belongs_to_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#score' => ['attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#score=' => ['attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_score' => ['attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#secret_score' => [nil, 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Widget#nickname' => ['alias_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#nickname=' => ['alias_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#theme' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#color=' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.recent' => ['scope', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#config_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#config_flag=' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#config_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.config_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.config_flag=' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.quiet_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.quiet_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.notes' => [nil, 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Widget.score' => [nil, 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Widget#recent' => [nil, 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Widget.flagged' => ['scope', 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Widget#flagged' => [nil, 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Widget.sealed' => ['scope', 'RailsMacroOracle::Widget'],
    # The names an option renames, and every name a call carries.
    'RailsMacroOracle::Widget#settings_tone' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#settings_tone=' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#shade_pref' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#shade_pref=' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#paint_hue' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#alpha_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.beta_flag=' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#beta_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    # Under a bare `private` in the body.
    'RailsMacroOracle::Widget#hidden_notes' => ['has_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_notes=' => ['has_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_keeper' => ['belongs_to', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_alias' => ['alias_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_alias=' => ['alias_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_theme' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_theme=' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.hidden_recent' => ['scope', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_flag=' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget#hidden_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.hidden_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.hidden_flag=' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Widget.hidden_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    # Inherited by a subclass with an empty body.
    'RailsMacroOracle::Gadget#notes' => ['has_many', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#keeper=' => ['belongs_to', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#score' => ['attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#hidden_score' => ['attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#nickname=' => ['alias_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#theme' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#hidden_theme' => ['store_accessor', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget.recent' => ['scope', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget.flagged' => ['scope', 'RailsMacroOracle::BaseRecord'],
    'RailsMacroOracle::Gadget.sealed' => ['scope', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget.hidden_recent' => ['scope', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#config_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget.config_flag=' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget#hidden_flag' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::Gadget.hidden_flag?' => ['class_attribute', 'RailsMacroOracle::Widget'],
    'RailsMacroOracle::PanelController#pick_layout' => [nil, 'RailsMacroOracle::BasePanelController'],
    'RailsMacroOracle::PanelController#recover' => [nil, 'RailsMacroOracle::BasePanelController'],
    'RailsMacroOracle::PanelController#rails_oracle_panel' => [nil, 'RailsMacroOracle::BasePanelController']
  }.each do |identifier, (macro, level)|
    it "answers #{identifier} at #{level}#{" by #{macro}" if macro}, as Ruby resolves it" do
      data = answer(identifier)
      truth = runtime(identifier)

      expect(data).to include('member'), data.inspect
      expect(data['member']['defined_by']).to eq(macro)
      expect(data.dig('inherited_from', 'identifier') || data.dig('member_of', 'identifier')).to eq(level)
      expect(owned_at?(truth[:method].owner, Object.const_get(level)) || regenerated?(identifier, macro, truth))
        .to be(true), truth[:method].owner.inspect
      expect(data['member']['visibility']).to eq(truth[:visibility])
      expect(data['statement']).to include("is a #{truth[:visibility]} ")
      file, line = truth[:method].source_location
      expect(data['member']['file_line']).to eq(line) if file == data.dig('member_of', 'file_path')
    end
  end

  # Active Record does not generate an attribute method a superclass below
  # it already implements.
  it "answers a superclass's def over the model's own attribute, as Ruby does" do
    data = answer('RailsMacroOracle::Widget#secret_score')

    expect(runtime('RailsMacroOracle::Widget#secret_score')[:method].owner).to eq(RailsMacroOracle::BaseRecord)
    expect(data['other_definitions']).to include(include('defined_by' => 'attribute'))
  end

  it 'answers a concern the model includes ahead of the association module, as Ruby does' do
    data = answer('RailsMacroOracle::Widget#keeper')

    expect(runtime('RailsMacroOracle::Widget#keeper')[:method].owner).to eq(RailsMacroOracle::Ownable)
    expect(data['defined_in']).to include('identifier' => 'RailsMacroOracle::Ownable')
    expect(data['other_definitions']).to include(include('defined_by' => 'belongs_to'))
  end

  {
    'RailsMacroOracle::Widget.badge' => nil, 'RailsMacroOracle::Widget#quiet_flag' => nil,
    'RailsMacroOracle::Widget#quiet_flag=' => nil, 'RailsMacroOracle::Widget#quiet_flag?' => nil
  }.each_key do |identifier|
    it "answers #{identifier} not found, with no macro named, as Ruby does not respond" do
      expect(runtime(identifier)).to be_nil
      expect(answer(identifier)).to be_nil
      expect(missing(identifier)).not_to include('may define it')
    end
  end

  # The reader Ruby calls is the column's, which the published source does
  # not hold, so the member is not found; neither call is named as one that
  # may define it.
  # A literal a call carries that is not a method name: an attribute's type,
  # a store key an option renames, the store column, an alias's target.
  {
    'RailsMacroOracle::Widget#integer' => false, 'RailsMacroOracle::Widget#integer=' => false,
    'RailsMacroOracle::Widget#tone' => false, 'RailsMacroOracle::Widget#tone=' => false,
    'RailsMacroOracle::Widget#shade' => false, 'RailsMacroOracle::Widget#shade=' => false,
    'RailsMacroOracle::Widget#hue' => false, 'RailsMacroOracle::Widget#pref' => false,
    'RailsMacroOracle::Widget#settings' => true, 'RailsMacroOracle::Widget#title' => true
  }.each do |identifier, column|
    it "does not answer #{identifier} as defined by the call that carries it" do
      truth = runtime(identifier)

      if column
        expect(truth[:method].owner.name).to eq('RailsMacroOracle::Widget::GeneratedAttributeMethods')
      else
        expect(truth).to be_nil
      end
      expect(answer(identifier)).to be_nil
      expect(missing(identifier)).not_to include('may define it')
    end
  end

  it 'reads a store key under a prefix that is not a literal as one the call may define' do
    expect(runtime('RailsMacroOracle::Widget#glow')).to be_nil
    expect(runtime('RailsMacroOracle::Widget#lamp_glow')).not_to be_nil
    expect(answer('RailsMacroOracle::Widget#glow')).to be_nil
    expect(missing('RailsMacroOracle::Widget#glow')).to include('`store_accessor` at line').and include('may define it')
  end

  it 'does not read serialize or has_secure_token as a definition of the column they name' do
    %w[RailsMacroOracle::Widget#prefs RailsMacroOracle::Widget#token].each do |identifier|
      expect(runtime(identifier)[:method].owner.name).to eq('RailsMacroOracle::Widget::GeneratedAttributeMethods')
      expect(answer(identifier)).to be_nil
      expect(missing(identifier)).not_to include('may define it')
    end
  end
end
