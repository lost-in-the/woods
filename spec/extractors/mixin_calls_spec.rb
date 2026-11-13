# frozen_string_literal: true

require 'spec_helper'
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
      [[:include, 'Depot::Weighable'], [:include, '::Depot::Countable'], [:extend, 'self::ClassMethods']]
    )
  end

  it 'reads nothing from an empty or missing source' do
    expect([calls(''), calls(nil), described_class.outside_owner('', 'Owner')]).to eq([[], [], []])
  end

  it 'filters by kind' do
    expect(calls("module M\n  include A\n  extend B\nend\n", [:extend])).to eq([[:extend, 'B']])
  end
end
