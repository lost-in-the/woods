# frozen_string_literal: true

require 'spec_helper'
require 'woods/method_table'

# The method table read without evaluation, compared with what Ruby reports
# once the same source is evaluated: every entry's kind and visibility, and
# every method Ruby defines on each owner (instance and singleton side).
RSpec.describe Woods::MethodTable, 'against the Ruby runtime' do
  fixtures = {
    'default and bare visibility forms' => <<~RUBY,
      class Account
        def shown; end
        private def slug; end
        protected
        def guard; end
        public
        def later; end
        private :later
        private
        def hidden; end
        def self.helper; end
      end
    RUBY
    'always-private names under a bare public' => <<~RUBY,
      class Widget
        public
        def initialize; end
        def initialize_copy(other); end
        def initialize_dup(other); end
        def initialize_clone(other, freeze: nil); end
        def respond_to_missing?(name, include_all); end
        def call; end
      end
    RUBY
    'always-private names made public explicitly' => <<~RUBY,
      class Widget
        def initialize; end
        public :initialize
        public def initialize_copy(other); end
        protected def initialize_dup(other); end
      end
    RUBY
    'always-private names on the singleton side' => <<~RUBY,
      class Widget
        def self.initialize; end
        class << self
          def respond_to_missing?(name, include_all); end
        end
      end
    RUBY
    'bare module_function' => <<~RUBY,
      module Util
        module_function
        def a; end
        def initialize; end
        private
        def b; end
      end
    RUBY
    'inline module_function' => "module Util\n  module_function def a; end\n  def b; end\nend\n",
    'module_function with symbol and string arguments' => <<~RUBY,
      module Util
        def a; end
        def b; end
        def c; end
        def d; end
        private def e; end
        module_function :a
        module_function :b, 'c', :e
      end
    RUBY
    'module_function then visibility calls' => <<~RUBY,
      module Util
        module_function
        def a; end
        def b; end
        def c; end
        def d; end
        def f; end
        public :a
        protected :b
        private :c
        private_class_method :d
        class << self
          private :f
        end
      end
    RUBY
    'private_class_method and public_class_method' => <<~RUBY,
      class Report
        private_class_method def self.a; end
        def self.b; end
        def self.c; end
        def self.d; end
        private_class_method :b, 'c'
        private_class_method [:d]
        public_class_method :d
        public_class_method def self.e; end
        def b; end
      end
    RUBY
    'symbol, string and array visibility arguments' => <<~RUBY,
      class Account
        def a; end
        def b; end
        def c; end
        def d; end
        private :a, 'b'
        protected [:c]
        private :d
        public :d
        class << self
          def f; end
          private :f
          def g; end
        end
      end
    RUBY
    'nested owners' => <<~RUBY
      module Outer
        def self.a; end
        class Inner
          private
          def b; end
          class << self
            protected def c; end
          end
        end
      end
    RUBY
  }.freeze

  # [owner, side, name] => visibility, from the table.
  def table_facts(source)
    described_class.call(source).each_with_object({}) do |entry, facts|
      owner, name, visibility = entry.values_at('owner', 'name', 'visibility')
      case entry['kind']
      when 'instance' then facts[[owner, :instance, name]] = visibility
      when 'singleton' then facts[[owner, :singleton, name]] = visibility
      when 'module_function'
        facts[[owner, :instance, name]] = 'private'
        facts[[owner, :singleton, name]] = visibility
      end
    end
  end

  # The same facts as Ruby reports them for every owner the table names.
  def runtime_facts(source, owners)
    namespace = Module.new
    namespace.module_eval(source)
    owners.each_with_object({}) do |owner, facts|
      constant = namespace.const_get(owner)
      { instance: constant, singleton: constant.singleton_class }.each do |side, target|
        %w[public private protected].each do |visibility|
          target.send(:"#{visibility}_instance_methods", false).each do |name|
            facts[[owner, side, name.to_s]] = visibility
          end
        end
      end
    end
  end

  fixtures.each do |label, source|
    it "agrees with Ruby for #{label}" do
      table = table_facts(source)
      owners = table.keys.map(&:first).uniq
      expect(table).to eq(runtime_facts(source, owners))
    end
  end
end
