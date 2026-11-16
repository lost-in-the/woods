# frozen_string_literal: true

require 'spec_helper'
require 'woods/ast'
require 'woods/ruby_analyzer/method_analyzer'

# The static map's method units, compared with what Ruby reports once the
# same source is evaluated: every method Ruby defines on each module and
# class, instance and singleton side, with its visibility, and no unit for
# a method Ruby does not define.
RSpec.describe Woods::RubyAnalyzer::MethodAnalyzer, 'against the Ruby runtime' do
  fixtures = {
    'definitions passed to visibility and class-method calls' => <<~RUBY,
      class Worker
        def visible; end
        def self.plain; end
        private def hidden; end
        protected def guarded; end
        private
        def after_section; end
        public def shown; end
        private_class_method def self.secret; end
        public_class_method def self.open; end
      end
    RUBY
    'definitions under conditional and begin wrappers' => <<~RUBY,
      class Worker
        if true
          def under_if; end
        end
        unless false
          def under_unless; end
        end
        begin
          def under_begin; end
        end
        def under_modifier; end if true
      end
    RUBY
    'a definition passed to a method that is not a visibility call' => <<~RUBY,
      class Worker
        def self.memoize(name)
          name
        end
        memoize def total; end
      end
    RUBY
    'class << self with private def and a conditional' => <<~RUBY,
      class Worker
        class << self
          private def sing_private; end
          def sing_public; end
          if true
            def sing_conditional; end
          end
        end
      end
    RUBY
    'module_function inline and as a section' => <<~RUBY,
      module Util
        module_function def inline; end
        def plain; end
        module_function
        def section; end
      end
    RUBY
    'visibility Ruby applies after the definition or by name' => <<~RUBY
      class Worker
        def initialize; end
        def respond_to_missing?(*) = false
        def later; end
        private :later
      end
    RUBY
  }.freeze

  # [owner, side, name] => visibility, from the units.
  def unit_facts(source)
    described_class.new.analyze(source: source, file_path: '/app/sample.rb').to_h do |unit|
      owner, separator, name = unit.identifier.rpartition(/[#.]/)
      [[owner, separator == '#' ? :instance : :singleton, name], unit.metadata[:visibility].to_s]
    end
  end

  def runtime_facts(source)
    namespace = Module.new
    namespace.module_eval(source)
    owners(namespace).each_with_object({}) do |owner, facts|
      constant = namespace.const_get(owner)
      { instance: constant, singleton: constant.singleton_class }.each do |side, target|
        %w[public private protected].each do |visibility|
          names = target.send(:"#{visibility}_instance_methods", false)
          names.each { |name| facts[[owner, side, name.to_s]] = visibility }
        end
      end
    end
  end

  def owners(namespace, prefix = nil)
    namespace.constants(false).sort.flat_map do |name|
      value = namespace.const_get(name, false)
      next [] unless value.is_a?(Module)

      owner = [prefix, name].compact.join('::')
      [owner, *owners(value, owner)]
    end
  end

  fixtures.each do |label, source|
    it "agrees with Ruby for #{label}" do
      runtime = runtime_facts(source)
      expect(runtime).not_to be_empty
      expect(unit_facts(source)).to eq(runtime)
    end
  end

  it 'marks a definition under a conditional as a candidate, and leaves a definite one unmarked' do
    source = "class Worker\n  def plain; end\n  if Feature.on?\n    def maybe; end\n  end\nend\n"
    units = described_class.new.analyze(source: source, file_path: '/app/worker.rb')

    expect(units.to_h { |unit| [unit.identifier, unit.metadata[:candidate]] })
      .to eq('Worker#plain' => nil, 'Worker#maybe' => 'conditional')
  end

  it 'publishes a definition in a block of the class body only as a block candidate' do
    source = "class Plugin\n  Registry.create do\n    def run\n      Runner.start\n    end\n  end\nend\n"
    unit = described_class.new.analyze(source: source, file_path: '/app/plugin.rb').first

    expect(unit.identifier).to eq('Plugin#run')
    expect(unit.metadata).to include(candidate: 'block', call_graph: [{ target: 'Runner', method: 'start', line: 4 }])
  end
end
