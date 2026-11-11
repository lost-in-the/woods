# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/model_name_cache'
require 'woods/extractors/shared_utility_methods'
require 'woods/extractors/shared_dependency_scanner'
require 'woods/extractors/state_machine_extractor'

RSpec.describe Woods::Extractors::StateMachineExtractor do
  include_context 'extractor setup'

  it_behaves_like 'extracts multibyte source under a POSIX locale',
                  path: 'app/models/shipment.rb',
                  source: <<~SOURCE,
                    # Shipment — lifecycle
                    class Shipment < ApplicationRecord
                      include AASM
                      aasm do
                        state :pending, initial: true
                        state :sent
                      end
                    end
                  SOURCE
                  identifier: 'Shipment::aasm'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing app/models directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers state machines in app/models/' do
      create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:state_machine)
    end

    it 'discovers model files in subdirectories' do
      create_file('app/models/billing/invoice.rb', <<~RUBY)
        class Billing::Invoice < ApplicationRecord
          include AASM
          aasm do
            state :draft, initial: true
            state :sent
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Billing::Invoice::aasm')
    end

    it 'returns empty array for models without state machines' do
      create_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
          has_many :orders
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to eq([])
    end
  end

  # ── AASM ─────────────────────────────────────────────────────────────

  describe '#extract_model_file — AASM' do
    it 'detects AASM state machine' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:state_machine)
      expect(unit.identifier).to eq('Order::aasm')
      expect(unit.file_path).to eq(path)
    end

    it 'extracts states from AASM block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing
            state :completed
            state :cancelled
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:states]).to contain_exactly('pending', 'processing', 'completed', 'cancelled')
    end

    it 'detects initial state from state declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'detects initial state from aasm declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm initial: :pending do
            state :pending
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'extracts events with transitions' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing

            event :start_processing do
              transitions from: :pending, to: :processing
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      events = units.first.metadata[:events]
      expect(events.size).to eq(1)
      expect(events.first[:name]).to eq('start_processing')
      expect(events.first[:transitions]).to eq([{ from: 'pending', to: 'processing', guard: nil }])
    end

    it 'extracts event transitions with guards' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed, guard: :valid?
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      transition = units.first.metadata[:events].first[:transitions].first
      expect(transition[:guard]).to eq('valid?')
    end

    it 'extracts multiple events' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :processing
            state :completed

            event :start do
              transitions from: :pending, to: :processing
            end

            event :finish do
              transitions from: :processing, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      events = units.first.metadata[:events]
      expect(events.map { |e| e[:name] }).to contain_exactly('start', 'finish')
    end

    it 'sets gem_detected to aasm' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:gem_detected]).to eq('aasm')
    end

    it 'extracts callbacks' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            after_transition do |order, transition|
              order.notify_customer
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:callbacks]).not_to be_empty
    end

    it 'sets source_code with annotation header' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.source_code).to include('# State machine (aasm) for Order')
    end

    it 'keeps a blockless event and the events that follow it (EXTB-17)' do
      # A blockless `event :noop` used to become `current_event` with depth 0
      # and was replaced — never emitted — by the next event declaration.
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            state :pending, initial: true
            state :paid

            event :noop

            event :pay do
              transitions from: :pending, to: :paid
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)

      events = units.first.metadata[:events]
      expect(events.map { |e| e[:name] }).to contain_exactly('noop', 'pay')
      expect(events.find { |e| e[:name] == 'noop' }[:transitions]).to eq([])
    end

    it 'keeps parsing events after a blockless event closes its enclosing block (EXTB-17)' do
      # With the blockless event left current, the enclosing `end` drove
      # depth to -1 and every later event failed the `depth.zero?` guard.
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            state :pending, initial: true

            event :noop
          end

          aasm do
            event :pay do
              transitions from: :pending, to: :paid
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)

      expect(units.first.metadata[:events].map { |e| e[:name] }).to include('noop', 'pay')
    end

    it 'does not open a block on a do inside a comment' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              transitions from: :pending, to: :paid # do not retry here
            end

            event :ship do
              transitions from: :paid, to: :shipped
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] },
                             { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] }
                           ])
    end

    it 'does not open a block on a do inside a string' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              after { log("nothing to do") }
              transitions from: :pending, to: :paid
            end

            event :ship do
              transitions from: :paid, to: :shipped
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events.map { |e| e[:name] }).to eq(%w[pay ship])
      expect(events.last[:transitions]).to eq([{ from: 'paid', to: 'shipped', guard: nil }])
    end

    it 'closes an event on an end line with trailing content' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              transitions from: :pending, to: :paid, guard: :funded?
            end # pay

            event :ship do
              after { notify(:shipped) }
              transitions from: :paid, to: :shipped
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: 'funded?' }] },
                             { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] }
                           ])
    end

    it 'does not close an event on the end of a nested if block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              before do
                if Rails.env.test?
                  log(:paid)
                end
              end
              transitions from: :pending, to: :paid
            end

            event :ship do
              transitions from: :paid, to: :shipped
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] },
                             { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] }
                           ])
    end

    # Keyword matching without token context counted a method named
    # `class` and a `:begin` symbol as block openers, so the event's own
    # `end` never closed it and the next event's transitions joined it.
    ['object.class', ':begin', 'state_options(begin: 1)'].each do |body_line|
      it "keeps events apart when an event body holds #{body_line}" do
        path = create_file('app/models/order.rb', <<~RUBY)
          class Order < ApplicationRecord
            include AASM

            aasm do
              event :pay do
                #{body_line}
                transitions from: :pending, to: :paid
              end
              event :ship do
                transitions from: :paid, to: :shipped
              end
            end
          end
        RUBY

        events = described_class.new.extract_model_file(path).first.metadata[:events]

        expect(events).to eq([
                               { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] },
                               { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] }
                             ])
      end
    end

    # The event walker descended into method bodies, so a runtime call named
    # `event` in an instance method was read as a declared event.
    it 'ignores an event call inside a method body' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              transitions from: :pending, to: :paid
            end
          end

          def notify_tracker
            event(:payment_sent)
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events.map { |event| event[:name] }).to eq(['pay'])
    end

    # Events were looked for in the whole model, so an `event` call in a
    # callback or a define_method block was read as a declared event.
    {
      'a callback block' => 'after_commit { event(:payment_sent) }',
      'a define_method block' => "define_method(:notify_tracker) do\n    event(:payment_seen)\n  end"
    }.each do |label, body|
      it "ignores an event call in #{label} outside the aasm definition" do
        path = create_file('app/models/order.rb', <<~RUBY)
          class Order < ApplicationRecord
            include AASM

            aasm do
              event :pay do
                transitions from: :pending, to: :paid
              end
            end

            #{body}
          end
        RUBY

        events = described_class.new.extract_model_file(path).first.metadata[:events]

        expect(events.map { |event| event[:name] }).to eq(['pay'])
      end
    end

    # AASM 6.0.0's own registry for this model holds `pay` (pending to paid)
    # and `ship` (paid to shipped). The callbacks register deferred blocks;
    # the forwarded proc extends the same machine.
    it 'reads the events AASM registers, not calls inside callbacks' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            after_all_events { event(:payment_sent) }
            event :pay do
              after { transitions(from: :fake, to: :fake2) }
              transitions(from: :pending, to: :paid)
            end
          end

          aasm(&proc {
            event(:ship) {
              transitions(from: :paid, to: :shipped)
            }
          })
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] },
                             { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] }
                           ])
    end

    # AASM 6.0.0 accepts proc and Proc.new blocks at both levels; a forwarded
    # zero-argument lambda raises ArgumentError under its instance_eval, so it
    # defines nothing.
    it 'reads literal procs forwarded as blocks, and evaluates nothing else' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm(&Proc.new {
            event(:pay, &proc { transitions from: :pending, to: :paid })
          })
          aasm(&-> { event(:refund) { transitions from: :paid, to: :refunded } })
          aasm(&DEFINITION)
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([{ name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] }])
    end

    # AASM 6.0.0 registers all three: a receiver and an argument are
    # evaluated before the outer call. A block forwarded to a callback is not.
    it 'reads declarations evaluated as a receiver or an argument' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event(:pay) do
              transitions from: :pending, to: :paid
            end.tap {}
            event(:ship) { transitions(from: :paid, to: :shipped).tap {} }
            Array(event(:refund) { Array(transitions(from: :paid, to: :refunded)) })
            after_all_events(&proc { event(:noted) })
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] },
                             { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] },
                             { name: 'refund', transitions: [{ from: 'paid', to: 'refunded', guard: nil }] }
                           ])
    end

    # In AASM 6.0.0 every block below runs while the definition is read and
    # registers its event. An iterator's block runs as often as its receiver
    # has elements ([].each runs none), so it is not read; another object's
    # instance_eval raises NoMethodError.
    it 'reads declarations inside blocks Ruby runs once, at once' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            tap { event(:tapped) { transitions from: :a, to: :b } }
            self.then { event(:thened) { transitions from: :a, to: :b } }
            yield_self { event(:yielded) { transitions from: :a, to: :b } }
            instance_eval { event(:evaluated) { transitions from: :a, to: :b } }
            instance_exec { event(:executed) { tap { transitions from: :a, to: :b } } }
            event(:first) { transitions from: :a, to: :b }.tap { event(:second) }

            [1].each { event(:iterated) }
            Object.new.instance_eval { event(:foreign) }
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]
      transition = [{ from: 'a', to: 'b', guard: nil }]

      expect(events.map { |event| [event[:name], event[:transitions]] }).to eq(
        [['tapped', transition], ['thened', transition], ['yielded', transition], ['evaluated', transition],
         ['executed', transition], ['first', transition], ['second', []]]
      )
    end

    # AASM 6.0.0's registry for this model holds pay (pending to paid), ship
    # and archive. A lambda that is assigned, forwarded to a callback or
    # passed as a keyword option is never called while the definition is read.
    it 'reads no lambda the definition does not run' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            unused = -> { event(:ghost) }
            after_all_events(&-> { event(:payment_sent) })
            event :pay, after: -> { event(:keyword_event) } do
              unused_transition = -> { transitions(from: :fake, to: :fake2) }
              after(&-> { transitions(from: :fake3, to: :fake4) })
              transitions from: :pending, to: :paid, after: -> { transitions(from: :fake5, to: :fake6) }
            end
            event :ship, &->(*) { transitions from: :paid, to: :shipped }
          end
          aasm(&->(*) { event(:archive) { transitions from: :shipped, to: :pending } })
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events.map { |event| [event[:name], event[:transitions].map { |t| "#{t[:from]}->#{t[:to]}" }] }).to eq(
        [['pay', ['pending->paid']], ['ship', ['paid->shipped']], ['archive', ['shipped->pending']]]
      )
    end

    # AASM 6.0.0 registers ran, elsed and ensured here: a rescue clause runs
    # only on an error, a loop body as often as runtime values say, and
    # defined? never runs its operand.
    it 'reads no rescue clause, loop body or defined? operand' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            begin
              event(:ran)
            rescue StandardError
              event(:rescued)
            else
              event(:elsed)
            ensure
              event(:ensured)
            end
            event(:modified) rescue event(:rescue_modifier)
            while false
              event(:while_looped)
            end
            for state in [] do event(:for_looped) end
            defined?(event(:checked))
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events.map { |event| event[:name] }).to eq(%w[ran elsed ensured modified])
    end

    # AASM 6.0.0 runs both blocks with instance_eval, which passes one
    # argument. Each lambda below that accepts it registered its event in the
    # live registry; each that does not raised ArgumentError. The last event
    # keeps its name, as a blockless event would, but no transitions.
    it 'reads a forwarded lambda only when it accepts one argument' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm(&->(*) { event(:rest) { transitions from: :a, to: :b } })
          aasm(&->(_dsl) { event(:one, &->(_event) { transitions from: :a, to: :b }) })
          aasm(&->(dsl, extra = 1) { event(:optional) { transitions from: :a, to: :b } })
          aasm(&lambda { |dsl| event(:block_param) { transitions from: :a, to: :b } })
          aasm(&-> { _1; event(:numbered) { transitions from: :a, to: :b } })
          aasm(&->(dsl, **opts) { event(:keyword_rest) { transitions from: :a, to: :b } })

          aasm(&->() { event(:none) })
          aasm(&->(dsl, other) { event(:two) })
          aasm(&->(dsl, key:) { event(:required_keyword) })
          aasm(&->(**opts) { event(:keywords_only) })
          aasm(&-> { _2; event(:numbered_two) })
          aasm(&lambda { event(:bare_lambda) })
          aasm { event(:pay, &-> { transitions from: :a, to: :b }) }
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]
      transition = [{ from: 'a', to: 'b', guard: nil }]

      expect(events.to_h { |event| [event[:name], event[:transitions]] }).to eq(
        'rest' => transition, 'one' => transition, 'optional' => transition, 'block_param' => transition,
        'numbered' => transition, 'keyword_rest' => transition, 'pay' => []
      )
    end

    it 'keeps declarations nested in conditionals inside the definition' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            if ENV['REFUNDS']
              event :refund do
                transitions from: :paid, to: :refunded unless ENV['NO_PAID_REFUNDS']
              end
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([{ name: 'refund', transitions: [{ from: 'paid', to: 'refunded', guard: nil }] }])
    end

    it 'reads events from every aasm definition, including one in a concern block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          included do
            aasm(:payment) do
              event :pay do
                transitions from: :pending, to: :paid
              end
            end
          end

          aasm(:shipping, column: :shipping_state) do
            event :ship do
              transitions from: :packed, to: :shipped
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events.map { |event| event[:name] }).to eq(%w[pay ship])
    end

    it 'reads a transition declared on an explicit self the same as a receiverless one' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              self.transitions from: :pending, to: :paid
            end
            event :ship do
              transitions from: :paid, to: :shipped
            end
            event :void do
              ledger.transitions from: :paid, to: :void
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] },
                             { name: 'ship', transitions: [{ from: 'paid', to: 'shipped', guard: nil }] },
                             { name: 'void', transitions: [] }
                           ])
    end

    # The transition's whole source, block included, was scanned for
    # `guard:`, so a comment or a string inside its block became a guard.
    [
      '# guard: :blocked_by_comment',
      'after { audit("guard: blocked_by_string") }'
    ].each do |block_line|
      it "takes no guard from a transition block holding #{block_line}" do
        path = create_file('app/models/order.rb', <<~RUBY)
          class Order < ApplicationRecord
            include AASM

            aasm do
              event :pay do
                transitions from: :pending, to: :paid do
                  #{block_line}
                  after { audit(:paid) }
                end
                transitions from: :held, to: :paid, guard: :allowed?
              end
            end
          end
        RUBY

        events = described_class.new.extract_model_file(path).first.metadata[:events]

        expect(events).to eq([
                               { name: 'pay', transitions: [
                                 { from: 'pending', to: 'paid', guard: nil },
                                 { from: 'held', to: 'paid', guard: 'allowed?' }
                               ] }
                             ])
      end
    end

    it 'keeps an event block still open at the end of the source' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM

          aasm do
            event :pay do
              transitions from: :pending, to: :paid
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([{ name: 'pay', transitions: [{ from: 'pending', to: 'paid', guard: nil }] }])
    end

    it 'returns empty array for files without AASM' do
      path = create_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
          has_many :orders
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units).to eq([])
    end
  end

  # ── Statesman ────────────────────────────────────────────────────────

  describe '#extract_model_file — Statesman' do
    it 'detects Statesman state machine' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :processing
          state :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:state_machine)
      expect(unit.identifier).to eq('Order::statesman')
    end

    it 'extracts states from Statesman source' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :processing
          state :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:states]).to contain_exactly('pending', 'processing', 'completed')
    end

    it 'detects initial state from Statesman declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'extracts transitions from Statesman source' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine

          state :pending, initial: true
          state :processing
          state :completed

          transition from: :pending, to: :processing
          transition from: :processing, to: :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      transitions = units.first.metadata[:transitions]
      expect(transitions.size).to eq(2)
      expect(transitions.first).to eq({ from: 'pending', to: 'processing', guard: nil })
    end

    it 'sets gem_detected to statesman' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine
          state :pending, initial: true
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:gem_detected]).to eq('statesman')
    end

    it 'returns empty events array for Statesman (uses transitions not events)' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include Statesman::Machine
          state :pending, initial: true
          transition from: :pending, to: :completed
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:events]).to eq([])
    end
  end

  # ── state_machines gem ────────────────────────────────────────────────

  describe '#extract_model_file — state_machines gem' do
    it 'keeps events apart when an event body calls a method named class' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine initial: :pending do
            event :activate do
              record.class
              transition pending: :active
            end
            event :archive do
              transition active: :archived
            end
          end
        end
      RUBY

      events = described_class.new.extract_model_file(path).first.metadata[:events]

      expect(events).to eq([
                             { name: 'activate', transitions: [{ from: 'pending', to: 'active', guard: nil }] },
                             { name: 'archive', transitions: [{ from: 'active', to: 'archived', guard: nil }] }
                           ])
    end

    {
      'state_machine initial: :pending do' => 'state',
      'state_machine(initial: :pending) do' => 'state',
      'state_machine(:status, initial: :pending) do' => 'status'
    }.each do |declaration, attribute|
      it "extracts the supported declaration #{declaration}" do
        path = create_file('app/models/order.rb', <<~RUBY)
          class Order < ApplicationRecord
            #{declaration}
              state :pending
              state :active
              event :activate do
                transition pending: :active
              end
            end
          end
        RUBY

        units = described_class.new.extract_model_file(path)

        expect(units.map(&:identifier)).to eq(["Order::state_machine_#{attribute}"])
        expect(units.first.metadata).to include(
          states: %w[pending active], initial_state: 'pending',
          events: [{ name: 'activate', transitions: [{ from: 'pending', to: 'active', guard: nil }] }]
        )
      end
    end

    ['state_machine do', 'state_machine() do'].each do |declaration|
      it "uses the default attribute without options in #{declaration}" do
        path = create_file('app/models/order.rb', <<~RUBY)
          class Order < ApplicationRecord
            #{declaration}
              state :pending
            end
          end
        RUBY

        units = described_class.new.extract_model_file(path)

        expect(units.map(&:identifier)).to eq(['Order::state_machine_state'])
        expect(units.first.metadata).to include(states: ['pending'], initial_state: nil)
      end
    end

    it 'keeps default and parenthesized named machine facts separate' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine initial: :pending do
            state :pending
            state :active
            event :activate do
              transition pending: :active
            end
          end
          state_machine(:payment_status, initial: :unpaid) do
            state :unpaid
            state :paid
            event :pay do
              transition unpaid: :paid
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)

      expect(units.map(&:identifier)).to eq(%w[Order::state_machine_state Order::state_machine_payment_status])
      expect(units.map { |unit| unit.metadata[:initial_state] }).to eq(%w[pending unpaid])
      expect(units.map { |unit| unit.metadata[:states] }).to eq([%w[pending active], %w[unpaid paid]])
      expect(units.map { |unit| unit.metadata[:events].map { |event| event[:name] } }).to eq([['activate'], ['pay']])
    end

    it 'uses the matching block for a multiline parenthesized declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine(
            :status,
            initial: :pending
          ) do
            state :pending
            event :activate do
              transition pending: :active
            end
          end
        end
      RUBY

      unit = described_class.new.extract_model_file(path).fetch(0)

      expect(unit.identifier).to eq('Order::state_machine_status')
      expect(unit.metadata[:initial_state]).to eq('pending')
      expect(unit.metadata[:events].first[:name]).to eq('activate')
    end

    it 'does not turn comments, strings, unrelated receivers or method calls into declarations' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          # state_machine :comment do
          EXAMPLE = "state_machine :example do"
          other.state_machine(:foreign) do
            state :foreign
          end
          def description
            state_machine :method_call do
              state :method_call
            end
          end
        end
      RUBY

      expect(described_class.new.extract_model_file(path)).to eq([])
    end

    it 'does not guess a dynamic machine attribute or evaluate a dynamic initial state' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine(attribute_name, initial: :unknown) do
            state :unknown
          end
          state_machine(:status, initial: -> { raise 'initializer must not run' }) do
            state :pending
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)

      expect(units.map(&:identifier)).to eq(['Order::state_machine_status'])
      expect(units.first.metadata).to include(states: ['pending'], initial_state: nil)
    end

    it 'preserves a callback on the final line of a machine block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status do
            state :pending
            before_transition any => :active, do: :audit
          end
        end
      RUBY

      unit = described_class.new.extract_model_file(path).fetch(0)

      expect(unit.metadata[:callbacks]).to eq(['before_transition any => :active, do: :audit'])
    end

    {
      'nested class' => ["class Order\nclass Inner", "end\nend"],
      'sibling class' => ["class Order; end\nclass Sibling", 'end'],
      'singleton class' => ["class Order\nclass << self", "end\nend"],
      'receiver class_eval' => ["class Order\nOTHER.class_eval do", "end\nend"],
      'uncalled lambda' => ["class Order\nUNUSED = -> do", "end\nend"]
    }.each do |scope, (opening, closing)|
      it "does not attribute a #{scope} machine to the selected outer model" do
        path = create_file('app/models/order.rb', <<~RUBY)
          #{opening}
            state_machine(initial: :pending) do
              state :pending
            end
          #{closing}
        RUBY

        expect(described_class.new.extract_model_file(path)).to eq([])
      end
    end

    it 'extracts the governed selected nested class rather than its outer or sibling class' do
      path = create_file('app/models/billing/container/order.rb', <<~RUBY)
        module Billing
          class Container
            state_machine(:outer) do
              state :outer
            end
            class Order
              state_machine(initial: :pending) do
                state :pending
              end
            end
            class Sibling
              state_machine(:sibling) do
                state :sibling
              end
            end
          end
        end
      RUBY
      extractor = described_class.new
      allow(extractor).to receive(:governed_class_name).with(path, anything).and_return('Billing::Container::Order')

      units = extractor.extract_model_file(path)

      expect(units.map(&:identifier)).to eq(['Billing::Container::Order::state_machine_state'])
      expect(units.first.metadata[:states]).to eq(['pending'])
    end

    it 'preserves a qualified model declaration with an available owning namespace' do
      stub_const('Billing', Module.new)
      path = create_file('app/models/billing/order.rb', <<~RUBY)
        class Billing::Order
          self.state_machine(:status, initial: :pending) do
            state :pending
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)

      expect(units.map(&:identifier)).to eq(['Billing::Order::state_machine_status'])
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'detects state_machine block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:state_machine)
      expect(unit.identifier).to eq('Order::state_machine_status')
    end

    it 'extracts states from state_machines block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
            state :completed
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:states]).to contain_exactly('pending', 'active', 'completed')
    end

    it 'detects initial state from state_machine declaration' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:initial_state]).to eq('pending')
    end

    it 'extracts events with transitions from state_machines block' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active

            event :activate do
              transition pending: :active
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      events = units.first.metadata[:events]
      expect(events.size).to eq(1)
      expect(events.first[:name]).to eq('activate')
      expect(events.first[:transitions]).to eq([{ from: 'pending', to: 'active', guard: nil }])
    end

    it 'sets gem_detected to state_machines' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status do
            state :pending
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.metadata[:gem_detected]).to eq('state_machines')
    end

    it 'produces multiple units for multiple state_machine blocks' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          state_machine :status, initial: :pending do
            state :pending
            state :active
          end

          state_machine :payment_status, initial: :unpaid do
            state :unpaid
            state :paid
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly(
        'Order::state_machine_status',
        'Order::state_machine_payment_status'
      )
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    it 'includes a reference to the host model' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      deps = units.first.dependencies
      model_dep = deps.find { |d| d[:type] == :model && d[:target] == 'Order' }
      expect(model_dep).not_to be_nil
      expect(model_dep[:via]).to eq(:state_machine)
    end

    it 'scans callbacks for service dependencies' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed
            after_transition { |o| NotificationService.call(o) }
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      dep_targets = units.first.dependencies.map { |d| d[:target] }
      expect(dep_targets).to include('NotificationService')
    end

    it 'includes :via key on all dependencies' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            after_transition { |o| NotifyJob.perform_later(o) }
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      units.first.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Error handling ───────────────────────────────────────────────────

  describe 'error handling' do
    it 'returns empty array for nonexistent file' do
      units = described_class.new.extract_model_file('/nonexistent/path/model.rb')
      expect(units).to eq([])
    end
  end

  # ── Namespace ────────────────────────────────────────────────────────

  describe 'namespace' do
    it 'sets namespace for namespaced models' do
      path = create_file('app/models/billing/invoice.rb', <<~RUBY)
        class Billing::Invoice < ApplicationRecord
          include AASM
          aasm do
            state :draft, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.namespace).to eq('Billing')
    end

    it 'sets nil namespace for top-level models' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.namespace).to be_nil
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      meta = units.first.metadata

      expect(meta).to have_key(:gem_detected)
      expect(meta).to have_key(:states)
      expect(meta).to have_key(:events)
      expect(meta).to have_key(:transitions)
      expect(meta).to have_key(:initial_state)
      expect(meta).to have_key(:callbacks)
      expect(meta).to have_key(:model_name)
    end

    it 'populates transitions from events' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      meta = units.first.metadata
      expect(meta[:transitions]).to eq([{ from: 'pending', to: 'completed', guard: nil }])
    end
  end

  # ── Namespaced identifiers (#174) ────────────────────────────────────

  describe 'namespaced identifiers (#174)' do
    it 'qualifies a module-nested model with its enclosing namespace' do
      path = create_file('app/models/billing/payment.rb', <<~RUBY)
        module Billing
          class Payment < ApplicationRecord
            include AASM
            aasm do
              state :pending, initial: true
              state :captured
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.identifier).to eq('Billing::Payment::aasm')
      expect(units.first.namespace).to eq('Billing')
      expect(units.first.metadata[:model_name]).to eq('Billing::Payment')
    end

    it 'targets the fully-qualified model constant in dependencies' do
      path = create_file('app/models/billing/payment.rb', <<~RUBY)
        module Billing
          class Payment < ApplicationRecord
            include AASM
            aasm do
              state :pending, initial: true
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      model_dep = units.first.dependencies.find { |d| d[:type] == :model }
      expect(model_dep[:target]).to eq('Billing::Payment')
    end

    it 'qualifies a compact-form declaration' do
      path = create_file('app/models/billing/payment.rb', <<~RUBY)
        class Billing::Payment < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.identifier).to eq('Billing::Payment::aasm')
      expect(units.first.namespace).to eq('Billing')
    end

    it 'qualifies a module-nested state_machines gem declaration' do
      path = create_file('app/models/billing/payment.rb', <<~RUBY)
        module Billing
          class Payment < ApplicationRecord
            state_machine :status, initial: :pending do
              state :pending
              state :captured
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      expect(units.first.identifier).to eq('Billing::Payment::state_machine_status')
    end

    it 'keeps cross-namespace same-named models distinct' do
      create_file('app/models/billing/payment.rb', <<~RUBY)
        module Billing
          class Payment < ApplicationRecord
            include AASM
            aasm do
              state :pending, initial: true
            end
          end
        end
      RUBY
      create_file('app/models/legacy/payment.rb', <<~RUBY)
        module Legacy
          class Payment < ApplicationRecord
            include AASM
            aasm do
              state :archived, initial: true
            end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to contain_exactly(
        'Billing::Payment::aasm',
        'Legacy::Payment::aasm'
      )
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
            state :completed

            event :complete do
              transitions from: :pending, to: :completed
            end
          end
        end
      RUBY

      units = described_class.new.extract_model_file(path)
      hash = units.first.to_h

      expect(hash[:type]).to eq(:state_machine)
      expect(hash[:identifier]).to eq('Order::aasm')
      expect(hash[:source_code]).to include('# State machine (aasm) for Order')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      # JSON round-trip
      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('state_machine')
      expect(parsed['identifier']).to eq('Order::aasm')
    end
  end

  # ── Structured transition callbacks (#796) ───────────────────────────

  describe 'transition_callbacks' do
    def callbacks_for(source, path: 'app/models/post.rb')
      described_class.new.extract_model_file(create_file(path, source)).first.metadata[:transition_callbacks]
    end

    it 'publishes the literal scope, the method and its side effects' do
      entries = callbacks_for(<<~RUBY)
        class Post < ApplicationRecord
          state_machine :status, initial: :draft do
            # after_transition on: :archive, do: :forget
            after_transition on: :publish, do: :notify_subscribers
          end

          def notify_subscribers
            NotifySubscribersJob.perform_later(id)
          end
        end
      RUBY

      expect(entries.size).to eq(1)
      expect(entries.first).to include(kind: 'after_transition', on: ['publish'], from: [], to: [],
                                       method: 'notify_subscribers', block: false)
      expect(entries.first[:side_effects]).to include(jobs_enqueued: ['NotifySubscribersJob'], columns_written: [])
      expect(entries.first).not_to have_key(:unresolved)
    end

    it 'keeps the raw callback lines for the deprecation window' do
      path = create_file('app/models/post.rb', <<~RUBY)
        class Post < ApplicationRecord
          state_machine :status do
            after_transition on: :publish, do: :notify_subscribers
          end
        end
      RUBY

      metadata = described_class.new.extract_model_file(path).first.metadata
      expect(metadata[:callbacks]).to eq(['after_transition on: :publish, do: :notify_subscribers'])
    end

    it 'reads a from => to pair, arrays and positional methods' do
      entries = callbacks_for(<<~RUBY)
        class Vehicle < ApplicationRecord
          state_machine initial: :parked do
            before_transition :parked => :idling, :do => :put_on_seatbelt
            before_transition [:idling, :first_gear] => :parked, do: [:park, :log]
            after_failure :log_failure
            around_transition on: %i[ignite shift_up], do: :time
          end
        end
      RUBY

      expect(entries.map { |e| e.slice(:kind, :from, :to, :on, :method) }).to eq(
        [
          { kind: 'before_transition', from: ['parked'], to: ['idling'], on: [], method: 'put_on_seatbelt' },
          { kind: 'before_transition', from: %w[idling first_gear], to: ['parked'], on: [], method: 'park' },
          { kind: 'before_transition', from: %w[idling first_gear], to: ['parked'], on: [], method: 'log' },
          { kind: 'after_failure', from: [], to: [], on: [], method: 'log_failure' },
          { kind: 'around_transition', from: [], to: [], on: %w[ignite shift_up], method: 'time' }
        ]
      )
    end

    it 'leaves a scope that is not literal empty and names it, without evaluating it' do
      entries = callbacks_for(<<~RUBY)
        class Vehicle < ApplicationRecord
          state_machine do
            after_transition any - [:parked] => any, do: :log
            after_transition from: STATES, to: any, do: :log
          end
        end
      RUBY

      expect(entries.map { |e| e.slice(:from, :to, :unresolved) }).to eq(
        [{ from: [], to: [], unresolved: ['from'] }, { from: [], to: [], unresolved: ['from'] }]
      )
    end

    it 'marks a block or a proc and leaves it unanalysed' do
      entries = callbacks_for(<<~RUBY)
        class Post < ApplicationRecord
          state_machine :status do
            after_transition on: :publish do |post, transition|
              NotifySubscribersJob.perform_later(post.id)
            end
            before_transition on: :archive, do: ->(post) { post.touch }
          end
        end
      RUBY

      expect(entries.map { |e| e.slice(:method, :block, :side_effects, :unanalysed) }).to eq(
        [{ method: nil, block: true, side_effects: nil, unanalysed: 'block' },
         { method: nil, block: true, side_effects: nil, unanalysed: 'block' }]
      )
    end

    it 'says when the method is not defined in the model or its concerns' do
      entries = callbacks_for(<<~RUBY)
        class Post < ApplicationRecord
          state_machine :status do
            after_transition on: :publish, do: :inherited_hook
          end
        end
      RUBY

      expect(entries.first).to include(side_effects: nil, unanalysed: 'not defined in the model or its concerns')
    end

    it 'analyses a method an included app/models concern defines' do
      create_file('app/models/concerns/announces.rb', <<~RUBY)
        module Announces
          def announce
            AnnouncementMailer.published(self).deliver_later
          end
        end
      RUBY
      entries = callbacks_for(<<~RUBY)
        class Post < ApplicationRecord
          include Announces

          state_machine :status do
            after_transition to: :published, do: :announce
          end
        end
      RUBY

      expect(entries.first[:to]).to eq(['published'])
      expect(entries.first[:side_effects]).to include(mailers_triggered: ['AnnouncementMailer'])
    end

    it 'reports columns written against the loaded model\'s columns' do
      stub_const('Post', Class.new do
        def self.column_names = %w[published_at status]
        def self.table_exists? = true
      end)
      entries = callbacks_for(<<~RUBY)
        class Post < ApplicationRecord
          state_machine :status do
            after_transition to: :published, do: :stamp
          end

          def stamp
            update_column(:published_at, Time.current)
          end
        end
      RUBY

      expect(entries.first[:side_effects][:columns_written]).to eq(['published_at'])
    end

    it 'reads Statesman callbacks from the machine class' do
      entries = callbacks_for(<<~RUBY, path: 'app/models/order_state_machine.rb')
        class OrderStateMachine
          include Statesman::Machine

          state :pending, initial: true
          state :paid

          after_transition(from: :pending, to: :paid) do |order, transition|
            ReceiptJob.perform_later(order.id)
          end

          def self.helper
            after_transition(to: :ignored)
          end
        end
      RUBY

      expect(entries).to eq([{ kind: 'after_transition', on: [], from: ['pending'], to: ['paid'],
                               method: nil, block: true, side_effects: nil, unanalysed: 'block' }])
    end

    it 'publishes an empty list for a machine without callbacks' do
      expect(callbacks_for(<<~RUBY)).to eq([])
        class Order < ApplicationRecord
          include AASM
          aasm do
            state :pending, initial: true
          end
        end
      RUBY
    end
  end
end
