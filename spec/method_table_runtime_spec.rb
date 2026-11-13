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
    'private_class_method def under a bare module_function' => <<~RUBY,
      module Tools
        module_function

        private_class_method def helper
          1
        end
      end
    RUBY
    'public_class_method def under a bare module_function' => <<~RUBY,
      module Tools
        module_function
        public_class_method def helper; end
      end
    RUBY
    'private def under a bare module_function' => <<~RUBY,
      module Tools
        module_function
        private def helper; end
      end
    RUBY
    'protected and public def under a bare module_function' => <<~RUBY,
      module Tools
        module_function
        protected def guard; end
        public def shown; end
        public def initialize; end
      end
    RUBY
    'def self. forms under a bare module_function' => <<~RUBY,
      module Tools
        module_function
        def self.plain; end
        private_class_method def self.hidden; end
        public_class_method def self.shown; end
      end
    RUBY
    'module_function def under a bare private' => <<~RUBY,
      module Tools
        private
        module_function def helper; end
      end
    RUBY
    'nested owners' => <<~RUBY,
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
    'module_function :a over an earlier def self.a' => <<~RUBY,
      module Util
        def a; end
        private_class_method def self.a; end
        def b; end
        def self.b; end
        private_class_method :b
        module_function :a, :b
      end
    RUBY
    'def self.a after module_function :a' => <<~RUBY,
      module Util
        def a; end
        module_function :a
        def self.a; end
      end
    RUBY
    'def a after module_function :a' => <<~RUBY,
      module Util
        def a; end
        module_function :a
        def a; end
      end
    RUBY
    'bare module_function def, then def self.a and def a' => <<~RUBY,
      module Util
        module_function
        def a; end
        def b; end
        public
        def self.a; end
        def b; end
      end
    RUBY
    'def self.a, then a bare module_function def' => <<~RUBY,
      module Util
        def self.a; end
        module_function
        def a; end
      end
    RUBY
    'def a twice and private before a redefinition' => <<~RUBY,
      class Account
        def a; end
        private
        def a; end
        public
        def b; end
        private :b
        def b; end
      end
    RUBY
    'singleton redefinitions and class-method visibility around them' => <<~RUBY,
      class Account
        def self.a; end
        private_class_method :a
        def self.a; end
        def self.b; end
        class << self
          private
          def b; end
        end
        def self.c; end
        public_class_method :c
        private_class_method def self.c; end
      end
    RUBY
    'class-method visibility around module functions' => <<~RUBY
      module Util
        module_function
        def a; end
        private_class_method :a
        def b; end
        private_class_method :b
        public_class_method :b
        public
        def c; end
        def self.c; end
        private_class_method :c
        module_function :c
      end
    RUBY
  }.freeze

  # [owner, side, name] => [visibility, definition line], from the table.
  # Two entries for one method (a dead definition beside the live one) fail.
  def table_facts(source)
    described_class.call(source).each_with_object({}) do |entry, facts|
      owner, name, visibility, line = entry.values_at('owner', 'name', 'visibility', 'line')
      sides = { 'instance' => { instance: visibility }, 'singleton' => { singleton: visibility },
                'module_function' => { instance: 'private', singleton: visibility } }.fetch(entry['kind'])
      sides.each do |side, side_visibility|
        key = [owner, side, name]
        raise "two entries for #{key.inspect}" if facts.key?(key)

        facts[key] = [side_visibility, line]
      end
    end
  end

  # The same facts as Ruby reports them for every owner the table names.
  def runtime_facts(source, owners)
    namespace = Module.new
    namespace.module_eval(source)
    defined_facts(namespace, owners)
  end

  def defined_facts(namespace, owners)
    owners.each_with_object({}) do |owner, facts|
      constant = namespace.const_get(owner)
      { instance: constant, singleton: constant.singleton_class }.each do |side, target|
        %w[public private protected].each do |visibility|
          target.send(:"#{visibility}_instance_methods", false).each do |name|
            facts[[owner, side, name.to_s]] = [visibility, target.instance_method(name).source_location.last]
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

  # Without `module_function` there is no singleton `helper` to change, so
  # Ruby raises after defining the public instance method.
  {
    'private_class_method def' => "module Tools\n  private_class_method def helper\n    1\n  end\nend\n",
    'public_class_method def' => "module Tools\n  public_class_method def helper; end\nend\n"
  }.each do |label, source|
    it "agrees with what Ruby defined before #{label} without a singleton method raised" do
      namespace = Module.new
      expect { namespace.module_eval(source) }.to raise_error(NameError, /helper/)
      expect(table_facts(source)).to eq(defined_facts(namespace, %w[Tools]))
    end
  end
end
