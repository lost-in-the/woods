# frozen_string_literal: true

require 'spec_helper'
require 'woods/ast/parser'
require 'woods/ast/method_extractor'
require 'woods/flow_analysis/operation_extractor'

RSpec.describe Woods::FlowAnalysis::OperationExtractor do
  subject(:extractor) { described_class.new }

  let(:parser) { Woods::Ast::Parser.new }
  let(:method_extractor) { Woods::Ast::MethodExtractor.new(parser: parser) }

  def extract_method_ops(source, method_name)
    method_node = method_extractor.extract_method(source, method_name)
    extractor.extract(method_node)
  end

  describe '#extract' do
    [true, false].each do |prism|
      context "with #{prism ? 'Prism' : 'the alternate parser adapter'}" do
        before { allow(parser).to receive(:prism_available?).and_return(prism) }

        it 'extracts nested async arguments on literal receivers' do
          source = <<~RUBY
            def call
              'k'.then(ExportJob.perform_later(1))
              1.then(ExportJob.perform_later(2))
            end
          RUBY

          operations = extract_method_ops(source, 'call')

          expect(operations.map { |op| [op[:type], op[:target], op[:method], op[:args_hint]] }).to eq(
            [[:async, 'ExportJob', 'perform_later', ['1']], [:async, 'ExportJob', 'perform_later', ['2']]]
          )
        end

        def async_ops(body, params: nil)
          signature = params ? "call(#{params})" : 'call'
          extract_method_ops("def #{signature}\n#{body}\nend\n", 'call')
            .select { |op| op[:type] == :async }.map { |op| "#{op[:target]}.#{op[:method]}" }
        end

        {
          'a hash value' => 'x = { job: HashJob.perform_later }',
          'a string interpolation' => "x = \"a\#{StrJob.perform_later}\"",
          'a heredoc interpolation' => "x = <<~TXT\n  a \#{DocJob.perform_later}\nTXT",
          'a yield argument' => 'yield YieldJob.perform_later',
          'a later rescue branch' => "Work.call\nrescue ArgumentError\nA.call\nrescue TypeError\nLateJob.perform_later",
          'the else of a rescue' => "Work.call\nrescue ArgumentError\nA.call\nelse\nElseJob.perform_later"
        }.each do |form, body|
          it "extracts an enqueue in #{form}" do
            expect(async_ops(body)).to eq(["#{body[/\w+Job/]}.perform_later"])
          end
        end

        it 'extracts an enqueue in a default parameter value ahead of the body' do
          operations = extract_method_ops("def call(job: DefJob.perform_later)\n  Body.run\nend\n", 'call')

          expect(operations.map { |op| [op[:type], op[:target], op[:method]] }).to eq(
            [[:async, 'DefJob', 'perform_later'], [:call, 'Body', 'run']]
          )
        end

        {
          'a lambda in a hash value' => 'x = { cb: -> { HashJob.perform_later } }',
          'a stabby lambda' => 'cb = -> { LamJob.perform_later }',
          'a lambda block' => 'cb = lambda { LamJob.perform_later }',
          'a proc block' => 'cb = proc { ProcJob.perform_later }',
          'a Proc.new block' => 'cb = Proc.new { ProcJob.perform_later }',
          'a defined? operand' => 'x = defined?(DefJob.perform_later)',
          'a lambda default parameter value' => ['Body.run', 'cb: -> { LamJob.perform_later }']
        }.each do |form, (body, params)|
          it "extracts no enqueue from #{form}, which does not run where it is written" do
            expect(async_ops(body, params: params)).to eq([])
          end
        end

        it 'leaves the receiver of a singleton definition out of its operations' do
          method_node = parser.parse("def (Registry.build).hook\n  Body.run\nend\n").find_first(:defs)

          expect(extractor.extract(method_node).map { |op| [op[:target], op[:method]] }).to eq([%w[Body run]])
        end

        describe 'a method defined inside the analyzed method' do
          def flow(body)
            extract_method_ops("def call\n#{body}\nend\n", 'call').map { |op| [op[:type], op[:target], op[:method]] }
          end

          {
            'its default parameter values' => "def inner(job = InnerJob.perform_later)\nend",
            'its body' => "def inner\n  InnerJob.perform_later\nend",
            'the defaults and body of a nested def self.x' => "def self.inner(job = InnerJob.perform_later)\n  " \
                                                              "InnerJob.perform_later\nend",
            'the defaults of a nested lambda' => 'hook = ->(job = InnerJob.perform_later) { job }'
          }.each do |form, nested|
            it "leaves #{form} out of the enclosing flow, which runs none of it" do
              expect(flow("#{nested}\nBody.run")).to eq([[:call, 'Body', 'run']])
            end
          end

          it 'keeps the receiver expression of a nested singleton definition, which runs when it is defined' do
            expect(flow("def (Hooks.build).inner(job = InnerJob.perform_later)\nend"))
              .to eq([[:call, 'Hooks', 'build']])
          end

          it 'reports the nested method defaults when that method is analyzed' do
            source = "def call\n  def inner(job = InnerJob.perform_later)\n    Body.run\n  end\nend\n"
            inner = parser.parse(source).find_all(:def).find { |node| node.method_name == 'inner' }

            expect(extractor.extract(inner).map { |op| [op[:type], op[:target], op[:method]] })
              .to eq([[:async, 'InnerJob', 'perform_later'], [:call, 'Body', 'run']])
          end

          it 'still lists every method of a whole source' do
            root = parser.parse("class Ledger\n  def a\n    First.run\n  end\n\n  " \
                                "def b(job = SecondJob.perform_later)\n    Third.run\n  end\nend\n")

            expect(extractor.extract(root).map { |op| [op[:type], op[:target], op[:method]] }).to eq(
              [[:call, 'First', 'run'], [:async, 'SecondJob', 'perform_later'], [:call, 'Third', 'run']]
            )
          end
        end

        it 'still extracts an enqueue in a block body' do
          expect(async_ops('items.each { EachJob.perform_later }')).to eq(['EachJob.perform_later'])
        end

        describe 'an enqueue in an expression a call evaluates' do
          {
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
            'a block nested in an argument' => 'Audit.record(items.map { MapJob.perform_later })'
          }.each do |form, body|
            it "is an async operation in #{form}" do
              expect(async_ops(body)).to eq(["#{body[/\w+Job/]}.perform_later"])
            end
          end

          {
            'a lambda argument' => 'Audit.record(-> { LamJob.perform_later })',
            'a lambda keyword argument' => 'Audit.record(callback: -> { LamJob.perform_later })',
            'a lambda block-pass' => 'Audit.record(&-> { LamJob.perform_later })',
            'a lambda block argument' => 'Audit.record(lambda { LamJob.perform_later })',
            'a lambda in an array argument' => 'Audit.record([-> { LamJob.perform_later }])',
            'a proc argument' => 'Audit.record(proc { ProcJob.perform_later })',
            'a Proc.new keyword argument' => 'Audit.record(callback: Proc.new { ProcJob.perform_later })',
            'a proc block-pass' => 'Audit.record(&proc { ProcJob.perform_later })',
            'a defined? argument' => 'Audit.record(defined?(DefJob.perform_later))'
          }.each do |form, body|
            it "is no operation in #{form}" do
              expect(async_ops(body)).to eq([])
            end
          end

          it 'counts an enqueue in the block the call is given once' do
            expect(async_ops('Audit.record { BlockJob.perform_later }')).to eq(['BlockJob.perform_later'])
          end

          it 'counts a configured enqueue once' do
            expect(async_ops('SetJob.set(wait: 1).perform_later(id)')).to eq(['SetJob.set.perform_later'])
          end

          it 'adds no operation for an ordinary call in a receiver chain or an argument' do
            operations = extract_method_ops("def call\n  Ledger.where(id: Scope.ids).update_all(x: 1)\nend\n", 'call')

            expect(operations.map { |op| [op[:type], op[:target], op[:method]] })
              .to eq([[:call, 'Ledger.where', 'update_all']])
          end
        end
      end
    end

    it 'extracts method calls in source order' do
      source = <<~RUBY
        def create
          result = FindOrCreate.call(cart)
          Worker.perform_async(result.id)
          render_created(result)
        end
      RUBY

      ops = extract_method_ops(source, 'create')

      expect(ops.map { |o| o[:type] }).to eq(%i[call async response])
      expect(ops[0][:target]).to eq('FindOrCreate')
      expect(ops[0][:method]).to eq('call')
      expect(ops[1][:target]).to eq('Worker')
      expect(ops[1][:method]).to eq('perform_async')
      expect(ops[2][:render_method]).to eq('render_created')
      expect(ops[2][:status_code]).to eq(201)
    end

    it 'extracts transaction blocks with exact receiver' do
      source = <<~RUBY
        def call
          Checkout.transaction do
            cart.lock!
            checkout = Checkout.find_or_create_by!(cart: cart)
          end
        end
      RUBY

      ops = extract_method_ops(source, 'call')

      expect(ops.size).to eq(1)
      expect(ops[0][:type]).to eq(:transaction)
      expect(ops[0][:receiver]).to eq('Checkout')
      expect(ops[0][:nested].size).to eq(2)
      expect(ops[0][:nested][0][:method]).to eq('lock!')
      expect(ops[0][:nested][1][:method]).to eq('find_or_create_by!')
    end

    it 'extracts with_lock as transaction type' do
      source = <<~RUBY
        def process
          record.with_lock do
            record.update!(status: :done)
          end
        end
      RUBY

      ops = extract_method_ops(source, 'process')

      expect(ops.size).to eq(1)
      expect(ops[0][:type]).to eq(:transaction)
      expect(ops[0][:receiver]).to eq('record')
    end

    it 'extracts async enqueue calls' do
      source = <<~RUBY
        def create
          NotifyWorker.perform_async(user.id)
          EmailJob.perform_later(user.id)
          RetryWorker.perform_in(5, user.id)
          ScheduledJob.perform_at(time, user.id)
        end
      RUBY

      ops = extract_method_ops(source, 'create')
      async_ops = ops.select { |o| o[:type] == :async }

      expect(async_ops.size).to eq(4)
      expect(async_ops.map { |o| o[:method] }).to eq(%w[perform_async perform_later perform_in perform_at])
    end

    it 'extracts an async enqueue nested in another call\'s arguments, and nothing else nested (F5)' do
      source = <<~RUBY
        def create
          Audit.record(NotifyJob.perform_later(user.id), user.name)
          Audit.record(wrap(MailJob.perform_async(user.id)))
        end
      RUBY

      ops = extract_method_ops(source, 'create')

      expect(ops.map { |o| [o[:type], o[:target], o[:method]] }).to eq(
        [
          [:call, 'Audit', 'record'],
          [:async, 'NotifyJob', 'perform_later'],
          [:call, 'Audit', 'record'],
          [:async, 'MailJob', 'perform_async']
        ]
      )
    end

    it 'extracts response calls' do
      source = <<~RUBY
        def show
          render json: user
        end
      RUBY

      ops = extract_method_ops(source, 'show')
      response_ops = ops.select { |o| o[:type] == :response }

      expect(response_ops.size).to eq(1)
      expect(response_ops[0][:render_method]).to eq('render')
    end

    it 'extracts redirect_to with default 302' do
      source = <<~RUBY
        def create
          redirect_to root_path
        end
      RUBY

      ops = extract_method_ops(source, 'create')
      response_ops = ops.select { |o| o[:type] == :response }

      expect(response_ops.size).to eq(1)
      expect(response_ops[0][:status_code]).to eq(302)
      expect(response_ops[0][:render_method]).to eq('redirect_to')
    end

    it 'extracts head calls' do
      source = <<~RUBY
        def destroy
          head :no_content
        end
      RUBY

      ops = extract_method_ops(source, 'destroy')
      response_ops = ops.select { |o| o[:type] == :response }

      expect(response_ops.size).to eq(1)
      expect(response_ops[0][:status_code]).to eq(204)
      expect(response_ops[0][:render_method]).to eq('head')
    end

    it 'extracts conditional branches with significant ops' do
      source = <<~RUBY
        def update
          if user.save
            NotifyWorker.perform_async(user.id)
          else
            render_unprocessable_entity(user.errors)
          end
        end
      RUBY

      ops = extract_method_ops(source, 'update')

      cond = ops.find { |o| o[:type] == :conditional }
      expect(cond).not_to be_nil
      expect(cond[:kind]).to eq('if')
      expect(cond[:then_ops].size).to be >= 1
      expect(cond[:else_ops].size).to be >= 1
    end

    # L2. The parser compacted [condition, then, else], so a literal `nil`
    # condition dropped out and `children[1]` became the *else* body, which
    # handle_conditional then reported as then_ops.
    it 'keeps branch attribution when the condition is literal nil' do
      source = <<~RUBY
        def decide
          if nil
            NullWorker.perform_async
          else
            RealWorker.perform_async
          end
        end
      RUBY

      cond = extract_method_ops(source, 'decide').find { |o| o[:type] == :conditional }
      expect(cond).not_to be_nil

      expect(cond[:then_ops].map { |o| o[:target] }).to eq(['NullWorker'])
      expect(cond[:else_ops].map { |o| o[:target] }).to eq(['RealWorker'])
    end

    it 'keeps else-branch attribution when the then branch is absent' do
      source = <<~RUBY
        def decide
          if flag_set?
          else
            ElseWorker.perform_async
          end
        end
      RUBY

      cond = extract_method_ops(source, 'decide').find { |o| o[:type] == :conditional }
      expect(cond).not_to be_nil

      expect(cond[:then_ops]).to be_empty
      expect(cond[:else_ops].map { |o| o[:target] }).to eq(['ElseWorker'])
    end

    # EXTB-4. `Prism::UnlessNode` shared `convert_prism_if` and landed its
    # body in the *then* slot, so every flow document stated the opposite of
    # what the code does. The parser now swaps the slots for `unless`, which
    # makes the emitted `if <predicate>` reading exact.
    describe 'unless statements' do
      it 'attributes the else branch to the condition being true' do
        source = <<~RUBY
          def settle
            unless admin?
              AuditService.log
            else
              PaymentService.charge
            end
          end
        RUBY

        cond = extract_method_ops(source, 'settle').find { |o| o[:type] == :conditional }

        expect(cond).not_to be_nil
        expect(cond[:condition]).to eq('admin?')
        expect(cond[:then_ops].map { |o| o[:target] }).to eq(['PaymentService'])
        expect(cond[:else_ops].map { |o| o[:target] }).to eq(['AuditService'])
      end

      it 'attributes a modifier unless body to the condition being false' do
        source = <<~RUBY
          def settle
            PaymentService.charge unless admin?
          end
        RUBY

        cond = extract_method_ops(source, 'settle').find { |o| o[:type] == :conditional }

        expect(cond).not_to be_nil
        expect(cond[:condition]).to eq('admin?')
        expect(cond[:then_ops]).to be_empty
        expect(cond[:else_ops].map { |o| o[:target] }).to eq(['PaymentService'])
      end
    end

    # #216 / B-103. `handle_case` walked every child, so a call in the
    # predicate — the thing being switched *on* — was reported as an operation
    # performed inside a branch, and the condition was the entire multi-line
    # case statement rather than the one expression.
    describe 'case statements' do
      let(:case_source) do
        <<~RUBY
          def route
            case Classifier.classify(payload)
            when :urgent
              UrgentWorker.perform_async(payload.id)
            when :normal
              NormalWorker.perform_async(payload.id)
            else
              render_unprocessable_entity(payload)
            end
          end
        RUBY
      end

      it 'records the predicate as the condition, not the whole statement' do
        cond = extract_method_ops(case_source, 'route').find { |o| o[:type] == :conditional }

        expect(cond[:kind]).to eq('case')
        # `to_source` renders the receiver and method, not the arguments —
        # same shape handle_conditional produces for an `if`.
        expect(cond[:condition]).to eq('Classifier.classify')
        # The point of the fix: one expression, not the whole case statement.
        expect(cond[:condition].lines.size).to eq(1)
        expect(cond[:condition]).not_to include('when')
      end

      it 'does not count the predicate call as a branch operation' do
        cond = extract_method_ops(case_source, 'route').find { |o| o[:type] == :conditional }
        branch_targets = cond[:then_ops].map { |o| o[:target] }

        expect(branch_targets).to include('UrgentWorker', 'NormalWorker')
        expect(branch_targets).not_to include('Classifier')
      end

      it 'still extracts the branch operations themselves' do
        cond = extract_method_ops(case_source, 'route').find { |o| o[:type] == :conditional }

        expect(cond[:then_ops].map { |o| o[:type] }).to include(:async, :response)
      end

      # EXTB-15. A predicate-less `case` put its first `when` in children[0],
      # so `drop(1)` skipped that branch entirely and the condition rendered
      # as the literal text "when". The predicate slot is now positional (a
      # nil hole when absent), mirroring the L2 fix for `:if`.
      it 'keeps the first when branch when the case has no predicate' do
        source = <<~RUBY
          def route
            case
            when urgent?
              AService.call
            else
              BService.call
            end
          end
        RUBY

        cond = extract_method_ops(source, 'route').find { |o| o[:type] == :conditional }

        expect(cond).not_to be_nil
        # The first `when` branch used to be consumed by `drop(1)` and lost.
        expect(cond[:then_ops].map { |o| o[:target] }).to include('AService', 'BService')
        # No predicate to switch on, so no condition text — never the literal
        # word "when" read off the first branch node.
        expect(cond[:condition]).to be_nil
      end
    end

    # An operation is reported where its method is named, so a call laid out
    # over several lines points at the call, not at the receiver it starts on.
    describe 'multi-line calls' do
      it 'reports a chained call at the line of its method name' do
        source = <<~RUBY
          def show
            Homepage
              .fetch_banner(params[:id])
          end
        RUBY

        expect(extract_method_ops(source, 'show').first)
          .to include(target: 'Homepage', method: 'fetch_banner', line: 3, statement_line: 2)
      end

      it 'reports a call after a multi-line receiver at its own line' do
        source = <<~RUBY
          def create
            Handler.build(
              request,
              response
            ).set_cookie(:session)
          end
        RUBY

        expect(extract_method_ops(source, 'create').map { |o| [o[:method], o[:line]] })
          .to include(['set_cookie', 5])
      end

      it 'reports an implicit call at the line of its dot' do
        source = <<~RUBY
          def notify
            Notifier
              .(event)
          end
        RUBY

        expect(extract_method_ops(source, 'notify').first).to include(method: 'call', line: 3)
      end

      it 'reports an enqueue at the line of its enqueue method' do
        source = <<~RUBY
          def create
            SyncJob
              .perform_later(id)
          end
        RUBY

        expect(extract_method_ops(source, 'create').first).to include(type: :async, line: 3, statement_line: 2)
      end

      it 'adds no statement line to a call on one line' do
        ops = extract_method_ops("def x\n  Ledger.post!(entry)\nend\n", 'x')

        expect(ops.first).not_to have_key(:statement_line)
      end
    end

    # A predicate runs before either branch, so its calls belong at the
    # level the conditional sits at, ahead of it. `if @widget.save` is the
    # side effect of a typical create action; dropping it left only the
    # conditional and its responses.
    describe 'conditional predicates' do
      it 'emits a call in an if predicate ahead of the conditional' do
        source = <<~RUBY
          def create
            if @widget.save
              redirect_to @widget
            else
              render :new
            end
          end
        RUBY

        ops = extract_method_ops(source, 'create')

        expect(ops.map { |o| o[:type] }).to eq(%i[call conditional])
        expect(ops.first).to include(target: '@widget', method: 'save', line: 2)
      end

      it 'keeps the predicate call out of the branches' do
        source = <<~RUBY
          def create
            if Ledger.post!(entry)
              Audit.record(entry)
            end
          end
        RUBY

        cond = extract_method_ops(source, 'create').find { |o| o[:type] == :conditional }

        expect(cond[:then_ops].map { |o| o[:target] }).to eq(['Audit'])
      end

      it 'emits the predicate call of a conditional whose branches have no operations' do
        source = <<~RUBY
          def show
            return unless Policy.allowed?(user)

            @widget
          end
        RUBY

        expect(extract_method_ops(source, 'show').map { |o| [o[:target], o[:method]] })
          .to eq([%w[Policy allowed?]])
      end

      it 'emits the call a case statement switches on ahead of the conditional' do
        source = <<~RUBY
          def route
            case Classifier.classify(payload)
            when :urgent then UrgentWorker.perform_async(payload.id)
            end
          end
        RUBY

        ops = extract_method_ops(source, 'route')

        expect(ops.map { |o| [o[:type], o[:target]] }).to eq([[:call, 'Classifier'], [:conditional, nil]])
      end

      it 'keeps a call negated with ! in a predicate' do
        source = <<~RUBY
          def flush
            return self if new_record? || readonly? || !buffered_data_present?
          end
        RUBY

        expect(extract_method_ops(source, 'flush').map { |o| o[:method] })
          .to eq(%w[new_record? readonly? buffered_data_present?])
      end

      it 'keeps a call negated with not' do
        source = <<~RUBY
          def settle
            Ledger.post! unless not Gate.open?
          end
        RUBY

        expect(extract_method_ops(source, 'settle').first).to include(type: :call, target: 'Gate', method: 'open?')
      end

      it 'keeps a doubly negated call once' do
        source = <<~RUBY
          def warm
            @warm = !!Cache.warm?
          end
        RUBY

        expect(extract_method_ops(source, 'warm').map { |o| [o[:target], o[:method]] }).to eq([%w[Cache warm?]])
      end

      it 'emits an enqueue in a predicate as an async operation' do
        source = <<~RUBY
          def create
            render :queued if SyncJob.perform_later(widget.id)
          end
        RUBY

        expect(extract_method_ops(source, 'create').first).to include(type: :async, target: 'SyncJob')
      end
    end

    it 'skips conditionals with no significant ops' do
      source = <<~RUBY
        def show
          if user.present?
            user.to_s
          end
        end
      RUBY

      ops = extract_method_ops(source, 'show')
      cond_ops = ops.select { |o| o[:type] == :conditional }

      expect(cond_ops).to be_empty
    end

    it 'extracts dynamic dispatch calls' do
      source = <<~RUBY
        def process
          obj.send(:do_work, arg)
          obj.public_send(:other_work)
        end
      RUBY

      ops = extract_method_ops(source, 'process')
      dynamic_ops = ops.select { |o| o[:type] == :dynamic_dispatch }

      expect(dynamic_ops.size).to eq(2)
      expect(dynamic_ops[0][:method]).to eq('send')
      expect(dynamic_ops[1][:method]).to eq('public_send')
    end

    it 'filters out insignificant method calls' do
      source = <<~RUBY
        def process
          user = User.find(id)
          user.nil?
          user.present?
          user.to_s
          UserService.call(user)
        end
      RUBY

      ops = extract_method_ops(source, 'process')
      methods = ops.map { |o| o[:method] }

      expect(methods).not_to include('nil?')
      expect(methods).not_to include('present?')
      expect(methods).not_to include('to_s')
      expect(methods).to include('call')
    end

    # Ruby makes a `super` call after its arguments and before the block it
    # passes runs, at that point of the body, in whatever holds the call.
    describe 'super calls' do
      let(:source) do
        <<~RUBY
          def update
            super(BeforeJob.perform_later); AfterJob.perform_later
            if Gate.open?
              super
            end
            Report.transaction do
              super do
                YieldedJob.perform_later
              end
            end
          end
        RUBY
      end

      def shape(operations)
        operations.map do |op|
          held = described_class::NESTED_KEYS.filter_map { |key| op[key] }
          held.empty? ? (op[:target] || op[:type]).to_s : [op[:type].to_s, *held.map { |ops| shape(ops) }]
        end
      end

      [true, false].each do |prism|
        context "with #{prism ? 'Prism' : 'the alternate parser adapter'}" do
          before { allow(parser).to receive(:prism_available?).and_return(prism) }

          it 'marks each call where Ruby makes it when asked' do
            method_node = method_extractor.extract_method(source, 'update')

            expect(shape(described_class.new(super_calls: true).extract(method_node))).to eq(
              ['BeforeJob', 'super_call', 'AfterJob', 'Gate', ['conditional', ['super_call'], []],
               ['transaction', %w[super_call YieldedJob]]]
            )
          end

          it 'records no operation for a super call by default' do
            expect(shape(extract_method_ops(source, 'update'))).to eq(
              ['BeforeJob', 'AfterJob', 'Gate', ['transaction', ['YieldedJob']]]
            )
          end

          # A call's receiver and arguments run before the call, so a `super`
          # among them is made first; one in a conditional expression only on
          # that branch.
          it 'marks a super call that is a receiver or argument of another call, before that call' do
            method_node = method_extractor.extract_method(<<~RUBY, 'show')
              def show
                Log.write(super)
                Log.write(value: super)
                handed = Wrapper.wrap(super)
                super.merge(1).then { AfterJob.perform_later }
                Log.write(ready? ? super : nil)
                Audit.record(super())
              end
            RUBY

            expect(shape(described_class.new(super_calls: true).extract(method_node))).to eq(
              ['super_call', 'Log', 'super_call', 'Log', 'super_call', 'Wrapper', 'super_call', 'AfterJob',
               ['conditional', ['super_call'], []], 'Log', 'super_call', 'Audit']
            )
          end

          it 'marks a super call inside an interpolated argument, and none in a lambda argument' do
            method_node = method_extractor.extract_method(<<~'RUBY', 'show')
              def show
                Log.write("value: #{super}")
                Log.write(-> { super })
              end
            RUBY

            expect(shape(described_class.new(super_calls: true).extract(method_node)))
              .to eq(%w[super_call Log Log])
          end
        end
      end
    end

    it 'returns empty array for nil input' do
      expect(extractor.extract(nil)).to eq([])
    end

    it 'returns empty array for non-Node input' do
      expect(extractor.extract('not a node')).to eq([])
    end

    it 'preserves line numbers' do
      source = <<~RUBY
        def create
          UserService.call(params)
          render_created(result)
        end
      RUBY

      ops = extract_method_ops(source, 'create')

      ops.each do |op|
        expect(op[:line]).to be_a(Integer)
      end
    end
  end
end
