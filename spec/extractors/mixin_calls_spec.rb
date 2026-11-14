# frozen_string_literal: true

require 'spec_helper'
require 'active_support/concern'
require 'woods/extractors/mixin_calls'

RSpec.describe Woods::Extractors::MixinCalls do
  def calls(source, kinds = %i[include extend prepend])
    described_class.call(source, kinds)
  end

  it 'reads every constant argument of include, extend and prepend calls, in source order' do
    source = <<~RUBY
      module Stackable
        include Alpha, Beta
        include(Gamma)
        include ::Depot::Weighable
        extend Depot::Countable
        prepend Wrapping
        include Delta,
                Epsilon::Zeta
        included do
          include Inner
        end
        self.extend Selfish
        self.include Theta, Iota
      end
    RUBY
    expect(calls(source)).to eq(
      [[:include, 'Alpha'], [:include, 'Beta'], [:include, 'Gamma'], [:include, '::Depot::Weighable'],
       [:extend, 'Depot::Countable'], [:prepend, 'Wrapping'], [:include, 'Delta'], [:include, 'Epsilon::Zeta'],
       [:include, 'Inner'], [:extend, 'Selfish'], [:include, 'Theta'], [:include, 'Iota']]
    )
  end

  it 'ignores calls sent to another receiver and calls inside a method, which act on something else' do
    source = <<~RUBY
      module Trackable
        def self.included(base)
          base.extend(ClassMethods)
          base.include(Helpers)
          base.send(:include, Sending)
        end

        def self.extended(base)
          base.extend Extending
          extend Inside
        end

        def self.prepended(klass)
          klass.prepend Prepending
        end

        Registry.include Elsewhere

        module ClassMethods; end
      end
    RUBY
    expect(calls(source)).to eq([])
  end

  it 'reads calls on any receiver and inside methods, but not through send, when asked for every call' do
    source = <<~RUBY
      module Trackable
        include Own
        def self.included(base)
          base.extend(ClassMethods)
          base.include(Helpers)
          base.send(:include, Sending)
          extend Inside
        end
      end
    RUBY
    expect(described_class.call(source, %i[include extend prepend], own_only: false)).to eq(
      [[:include, 'Own'], [:extend, 'ClassMethods'], [:include, 'Helpers'], [:extend, 'Inside']]
    )
  end

  describe '.outside_owner' do
    it 'reads every call but drops a constant that resolves to a module the owner declares' do
      source = <<~RUBY
        module Outer
          module Helpers; end

          module Trackable
            module ClassMethods
              module Deep; end
            end

            include Helpers
            include ClassMethods::Deep
            extend self::ClassMethods

            def self.included(base)
              base.extend(Outer::Trackable::ClassMethods)
              base.include(::Trackable::ClassMethods)
            end
          end
        end
      RUBY
      expect(described_class.outside_owner(source, 'Outer::Trackable')).to eq(
        [[:include, 'Helpers'], [:include, '::Trackable::ClassMethods']]
      )
    end
  end

  it 'ignores comments, strings, heredocs, method names and non-constant arguments' do
    source = <<~'RUBY'
      module Stackable
        # The include of this module is optional; extend Later if needed.
        NOTE = "include Quoted"
        DOC = <<~TEXT
          prepend Heredoc
        TEXT
        def include_of(other); end
        def includes; :include; end
        extend self
        include helper_module
        include "#{Interp}"
      end
    RUBY
    expect(calls(source)).to eq([])
  end

  it 'ignores a =begin block' do
    expect(calls("module M\n=begin\ninclude Hidden\n=end\n  include Shown\nend\n")).to eq([[:include, 'Shown']])
  end

  it 'resolves a qualified declaration against the modules that enclose it' do
    source = <<~RUBY
      module Outer
        module Outer::Trackable
          module ClassMethods; end
          extend ClassMethods
          include Depot::Weighable
        end
      end
    RUBY
    expect(described_class.outside_owner(source, 'Outer::Trackable')).to eq([[:include, 'Depot::Weighable']])
  end

  describe 'self:: in a mixin call' do
    it 'is the module only in its body and its singleton methods, as Ruby evaluates self' do
      plain = Module.new do
        def self.included(base)
          base.instance_variable_set(:@hook_self, self)
          base.class_eval { @class_eval_self = self }
        end
      end
      concern = Module.new do
        extend ActiveSupport::Concern

        included { @included_self = self }
        class_methods { @class_methods_self = self }
      end
      includer = Class.new
      includer.include(plain, concern)

      expect(includer.instance_variable_get(:@hook_self)).to be(plain)
      expect(includer.instance_variable_get(:@class_eval_self)).to be(includer)
      expect(includer.instance_variable_get(:@included_self)).to be(includer)
      expect(concern::ClassMethods.instance_variable_get(:@class_methods_self)).to be(concern::ClassMethods)
    end

    it 'names the enclosing module where self is that module, and nothing where it is not' do
      source = <<~RUBY
        module Trackable
          extend self::ClassMethods
          def self.included(base)
            base.extend(self::ClassMethods)
            base.class_eval { include self::Helpers }
            base.instance_eval { extend self::Finders }
          end
          included do
            include self::Scopes
          end
          class_methods do
            include self::Queries
          end
          class << self
            include self::Singleton
            def extended(base)
              base.extend(self::Extending)
            end
          end
          def track
            extend self::Instance
          end
        end
      RUBY
      expect(calls(source)).to eq([[:extend, '::Trackable::ClassMethods']])
      expect(described_class.call(source, %i[include extend], own_only: false)).to eq(
        [[:extend, '::Trackable::ClassMethods'], [:extend, '::Trackable::ClassMethods'],
         [:extend, '::Trackable::Extending']]
      )
    end
  end

  describe 'owner:' do
    def every_call(source, owner)
      described_class.call(source, %i[extend], own_only: false, owner: owner)
    end

    it 'roots a namespace-stripped source at the owner' do
      sliced = "  module Trackable\n    extend self::ClassMethods\n  end\n"
      expect(every_call(sliced, 'Depot::Trackable')).to eq([[:extend, '::Depot::Trackable::ClassMethods']])
    end

    it 'leaves a source that already declares the owner by its full name as written' do
      {
        "module Depot\n  module Depot\n    module ClassMethods; end\n    extend self::ClassMethods\n  end\nend\n" =>
          ['Depot::Depot', '::Depot::Depot::ClassMethods'],
        "module Depot\n  module Trackable\n    extend self::ClassMethods\n  end\nend\n" =>
          ['Depot::Trackable', '::Depot::Trackable::ClassMethods'],
        "module Depot::Trackable\n  extend self::ClassMethods\nend\n" =>
          ['Depot::Trackable', '::Depot::Trackable::ClassMethods']
      }.each do |source, (owner, name)|
        expect(every_call(source, owner)).to eq([[:extend, name]])
        expect(described_class.outside_owner(source, owner, %i[extend])).to eq([]) if source.include?('ClassMethods;')
      end
    end
  end

  it 'names a constant from its path, not its text, keeping a leading ::' do
    source = <<~RUBY
      module Stackable
        include Depot:: # shared module
          Weighable
        include ::Depot::
          Countable
        extend self::ClassMethods
      end
    RUBY
    expect(calls(source)).to eq(
      [[:include, 'Depot::Weighable'], [:include, '::Depot::Countable'], [:extend, '::Stackable::ClassMethods']]
    )
  end

  it 'reads nothing from an empty or missing source' do
    expect([calls(''), calls(nil), described_class.outside_owner('', 'Owner')]).to eq([[], [], []])
  end

  it 'filters by kind' do
    expect(calls("module M\n  include A\n  extend B\nend\n", [:extend])).to eq([[:extend, 'B']])
  end
end
