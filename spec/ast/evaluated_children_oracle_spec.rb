# frozen_string_literal: true

require 'spec_helper'
require 'woods/ast/parser'
require 'woods/ast/call_site_extractor'
require 'woods/flow_analysis/operation_extractor'

# Runs each fixture method for real, records every call it makes on a
# constant, and checks the parsed call sites and enqueue operations against it.
RSpec.describe 'Parsed calls and enqueues against a real run' do
  # A stand-in for every constant the fixture names. Each call is logged as
  # written (`Receiver.method`, chains included) and returns a new recorder.
  let(:recorder_class) do
    Class.new do
      def initialize(name, log)
        @name = name
        @log = log
      end

      def method_missing(name, *_args, &_block)
        @log << "#{@name}.#{name}"
        self.class.new("#{@name}.#{name}", @log)
      end

      def respond_to_missing?(*)
        true
      end

      def to_s
        @name
      end

      def to_a
        [StandardError]
      end

      def to_hash
        {}
      end

      def to_proc
        proc {}
      end
    end
  end

  raises = "raise ArgumentError if mode == :arg\n    raise TypeError if mode == :type\n    "
  modes = [[:ok], [:arg], [:type]]

  # form => [method body, argument lists to run it with, run it with a block?, parameters]
  forms = {
    'a hash value' => ['x = { job: Report.build }'],
    'a hash key' => ['x = { Key.build => 1 }'],
    'a double splat in a hash' => ['x = { **Options.build }'],
    'a string interpolation' => ["x = \"a\#{Label.build}\""],
    'a heredoc interpolation' => ["x = <<~TXT\n      a \#{Letter.build}\n    TXT"],
    'an interpolation inside a call argument' => ["Log.info(\"done \#{Count.build}\")"],
    'a yield argument' => ['yield Item.build', [[]], true],
    'later rescue branches and the else of a begin' => [
      "begin\n    #{raises}Body.call\n    rescue ArgumentError\n      First.call\n    rescue TypeError\n      " \
      "Second.call\n    else\n      Otherwise.call\n    ensure\n      Always.call\n    end", modes
    ],
    'later rescue branches and the else of a method body' => [
      "#{raises}Body.call\n  rescue ArgumentError\n    First.call\n  rescue TypeError\n    Second.call\n  " \
      "else\n    Otherwise.call\n  ensure\n    Always.call", modes
    ],
    'a block-pass expression' => ['Runner.run(&Builder.build)'],
    'a splatted rescue list' => ["raise ArgumentError\n  rescue *Errors.list\n    Recover.call"],
    'default parameter values' => ['Body.call', [[]], false, 'mode = Mode.build, client: Client.new'],
    'an empty pair of parentheses' => ["x = ()\n    After.call"],
    'an array element' => ['x = [Entry.build]'],
    'both ternary branches' => ['x = flag ? Yes.build : No.build', [[nil, true], [nil, false]]],
    'a safe-navigation call' => ['x = Maybe&.build'],
    'a block body' => ['items.each { Step.build }'],
    'an ensure clause' => ["begin\n      Body.call\n    ensure\n      Always.call\n    end"],
    'case/when branches' => ["case mode\n    when :arg then Picked.build\n    else Other.build\n    end", modes],
    'case/in branches' => ["case mode\n    in :arg then Picked.build\n    else Other.build\n    end", modes],
    'a rescue modifier' => ["x = Integer('z') rescue Fallback.build"],
    'an or-assign value' => ['@x ||= Cached.build'],
    'a return value' => ['return Result.build'],
    'a super argument' => ['super(Parent.build)'],
    'a while body' => ["i = 0\n    while i < 1\n      Loop.build\n      i += 1\n    end"],
    'an && operand' => ['flag && Guarded.build'],
    'a multiple assignment' => ['a, b = Pair.build, 1'],
    'a next value' => ['items.each { next Skipped.build }'],
    'an index argument' => ['Store[Key.build]'],
    'an interpolated symbol' => ["x = :\"a\#{Tag.build}\""],
    'an interpolated regex' => ["x = /a\#{Pattern.build}/"],
    'a block parameter default' => ['items.each { |a, b = Fill.build| b }'],
    'a lambda parameter default' => ['x = ->(a = Fill.build) { a }.call'],
    'a singleton class of an expression' => ["class << Holder.build\n    end"],
    'a definition receiver expression' => ["def (Holder.build).hook\n    end"],
    'a rescue target' => ["raise ArgumentError\n  rescue => Holder.build.error\n    Recover.call"]
  }

  def fixture_source(body, params)
    "class Probe < Base\n  def run(#{params || 'mode = nil, flag = true, items = [1]'})\n    #{body}\n  end\nend\n"
  end

  def runtime_calls(source, invocations, with_block)
    log = []
    recorder = recorder_class
    base = Class.new do
      def run(*_args, **_kwargs); end
      def render(*_args, **_kwargs); end
    end
    base.define_singleton_method(:const_missing) { |name| recorder.new(name.to_s, log) }
    sandbox = Module.new
    sandbox.const_set(:Base, base)
    sandbox.module_eval(source, 'fixture.rb', 1)
    invocations.each do |args|
      with_block ? sandbox::Probe.new.run(*args) { |value| value } : sandbox::Probe.new.run(*args)
    end
    log.uniq
  end

  def parsed_method(source, prism)
    parser = Woods::Ast::Parser.new
    allow(parser).to receive(:prism_available?).and_return(prism)
    parser.parse(source).find_all(:def).find { |node| node.method_name == 'run' }
  end

  def parsed_calls(source, prism)
    Woods::Ast::CallSiteExtractor.new.extract(parsed_method(source, prism))
                                 .map { |call| "#{call[:receiver]}.#{call[:method_name]}" }
  end

  def parsed_enqueues(source, prism)
    async = []
    pending = Woods::FlowAnalysis::OperationExtractor.new.extract(parsed_method(source, prism))
    while (operation = pending.shift)
      async << "#{operation[:target]}.#{operation[:method]}" if operation[:type] == :async
      Woods::FlowAnalysis::OperationExtractor::NESTED_KEYS.each { |key| pending.concat(operation[key] || []) }
    end
    async.sort
  end

  # A recorder ignores the block it is given, so a block body never runs
  # here; those forms are left to the operation extractor's own spec.
  enqueue_forms = {
    'a keyword argument' => 'Audit.record(job: KwJob.perform_later)',
    'an array in a keyword argument' => 'Audit.record(jobs: [KwArrJob.perform_later])',
    'an array argument' => 'Audit.record([ArrJob.perform_later])',
    'a parenthesized argument' => 'Audit.record((ParJob.perform_later))',
    'a splatted array argument' => 'Audit.record(*[SplatJob.perform_later])',
    'a ternary argument' => 'Audit.record(flag ? TernJob.perform_later : nil)',
    'an || argument' => 'Audit.record(nil || OrJob.perform_later)',
    'a hash-literal argument' => 'Audit.record({ job: HashJob.perform_later })',
    'an interpolated argument' => "Audit.record(\"id \#{InterpJob.perform_later}\")",
    'a render hash' => 'render json: { id: RenderJob.perform_later.job_id }',
    'the receiver chain of an argument' => 'Audit.record(ChainJob.perform_later.job_id)',
    'the receiver chain of a statement' => 'id = StmtJob.perform_later.job_id',
    'a configured enqueue' => 'SetJob.set(wait: 1).perform_later',
    'a call nested in an argument' => 'Audit.record(Wrap.build(NestJob.perform_later))',
    'a lambda argument' => 'Audit.record(-> { LamJob.perform_later })',
    'a lambda keyword argument' => 'Audit.record(callback: -> { LamJob.perform_later })',
    'a lambda block-pass' => 'Audit.record(&-> { LamJob.perform_later })',
    'a proc block-pass' => 'Audit.record(&proc { ProcJob.perform_later })',
    'a Proc.new keyword argument' => 'Audit.record(callback: Proc.new { ProcJob.perform_later })',
    'a lambda in a hash value' => 'x = { cb: -> { LamJob.perform_later } }',
    'a stabby lambda' => 'cb = -> { LamJob.perform_later }',
    'a proc' => 'cb = proc { ProcJob.perform_later }',
    'a defined? operand' => 'x = defined?(DefJob.perform_later)',
    'a nested method default' => "def inner(job = InnerJob.perform_later)\n    end",
    'a nested method body' => "def inner\n      InnerJob.perform_later\n    end",
    'a nested def self.x' => "def self.inner(job = InnerJob.perform_later)\n      InnerJob.perform_later\n    end",
    'a nested lambda default' => 'hook = ->(job = InnerJob.perform_later) { job }'
  }

  [true, false].each do |prism|
    context "with #{prism ? 'Prism' : 'the parser gem'}" do
      forms.each do |form, (body, invocations, with_block, params)|
        it "finds every call a real run makes in #{form}" do
          source = fixture_source(body, params)
          ran = runtime_calls(source, invocations || [[]], with_block)

          expect(ran).not_to be_empty
          expect(parsed_calls(source, prism)).to include(*ran)
        end
      end

      enqueue_forms.each do |form, body|
        it "lists exactly the enqueues a real run makes in #{form}" do
          source = fixture_source(body, nil)
          ran = runtime_calls(source, [[]], false).select { |call| call.end_with?('.perform_later') }

          expect(parsed_enqueues(source, prism)).to eq(ran.sort)
        end
      end
    end
  end
end
