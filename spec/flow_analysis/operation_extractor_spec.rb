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
