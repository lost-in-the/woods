# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/method_effects'

RSpec.describe Woods::Extractors::MethodEffects do
  def build_unit(identifier, dependencies: [], type: :model)
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "app/models/#{identifier}.rb")
    unit.metadata = {}
    unit.dependencies = dependencies
    unit
  end

  def apply(source, identifier: 'Ledger', **options)
    unit = build_unit(identifier, dependencies: options.delete(:dependencies) || [])
    described_class.apply(unit, source, **options)
    unit
  end

  def effects(source, **options)
    apply(source, **options).metadata[:method_effects]
  end

  let(:ledger_source) do
    <<~RUBY
      class Ledger
        def refund!(amount)
          RefundJob.perform_later(id, amount)
          ReceiptMailer.refunded(self).deliver_later
          TallyService.call(self)
          self.status = 'refunded'
          update_column(:balance, 0)
          ActiveSupport::Notifications.instrument('ledger.refunded', id: id)
          Faraday.post('https://example.test/hook')
        end

        def quiet
          balance.zero?
        end
      end
    RUBY
  end

  describe 'direct effects of a public method' do
    subject(:recorded) { effects(ledger_source, column_names: %w[status balance name]) }

    it 'records each effect family under the method name' do
      expect(recorded['refund!']).to eq(
        analysis_status: 'analyzed',
        jobs_enqueued: ['RefundJob'],
        mail_sent: ['ReceiptMailer'],
        services_called: ['TallyService'],
        columns_written: %w[balance status],
        events_published: ['ledger.refunded'],
        external_calls: ['Faraday']
      )
    end

    it 'omits a method with no effects' do
      expect(recorded.keys).to eq(['refund!'])
    end
  end

  describe 'analysis status' do
    it 'marks a method with effects analyzed' do
      expect(effects(ledger_source, column_names: %w[status balance])['refund!'][:analysis_status]).to eq('analyzed')
    end

    it 'keeps an analyzed method with no effects out of the map' do
      source = "class Ledger\n  def refund!\n    RefundJob.perform_later\n  end\n\n  def quiet\n    1\n  end\nend\n"
      expect(effects(source).keys).to eq(['refund!'])
    end

    it 'lists a method whose text cannot be read as source_unavailable, so empty is not read as none' do
      allow_any_instance_of(Woods::Extractors::CallbackAnalyzer).to receive(:method_effects).and_return(nil)
      recorded = effects("class Ledger\n  def refund!\n    RefundJob.perform_later\n  end\nend\n")

      expect(recorded['refund!']).to eq(
        analysis_status: 'source_unavailable', jobs_enqueued: [], mail_sent: [], services_called: [],
        columns_written: [], events_published: [], external_calls: []
      )
    end
  end

  it 'leaves the metadata untouched when no method has an effect' do
    unit = apply("class Ledger\n  def quiet\n    1\n  end\nend\n")

    expect(unit.metadata).to eq({})
  end

  it 'leaves the unit untouched when the source does not parse' do
    unit = apply("class Ledger\n  def broken(\nend\n")

    expect(unit.metadata).to eq({})
  end

  it 'does not believe commented-out or quoted calls' do
    source = <<~RUBY
      class Ledger
        def note
          # RefundJob.perform_later(id)
          logger.info "ReceiptMailer.refunded(self) and Faraday.get"
        end
      end
    RUBY

    expect(effects(source)).to be_nil
  end

  it 'does not scan a sibling method or callback on the same line' do
    source = <<~RUBY
      class Ledger
        def quiet; 1; end; def dispatch; DispatchJob.perform_later; end
        def another_quiet; 2; end; after_commit { CallbackJob.perform_later }
      end
    RUBY
    dependencies = [
      { type: :job, target: 'DispatchJob', via: :job_enqueue },
      { type: :job, target: 'CallbackJob', via: :job_enqueue }
    ]
    unit = apply(source, dependencies: dependencies)

    expect(unit.metadata[:method_effects].keys).to eq(['dispatch'])
    expect(unit.dependencies.first[:through]).to eq('dispatch')
    expect(unit.dependencies.last).not_to have_key(:through)
  end

  it 'does not execute a nested method definition while analyzing its installer' do
    source = <<~RUBY
      class Ledger
        def install
          def dispatch
            NestedJob.perform_later
            ActiveSupport::Notifications.instrument('nested.event')
            Faraday.get(url)
          end
          InstalledJob.perform_later
        end
      end
    RUBY

    expect(effects(source)['install']).to include(
      jobs_enqueued: ['InstalledJob'], events_published: [], external_calls: []
    )
  end

  describe 'events and external calls' do
    it 'reads Wisper publishes only in a class that includes Wisper' do
      wisper = <<~RUBY
        class Ledger
          include Wisper::Publisher

          def close!
            broadcast(:ledger_closed, self)
            publish :ledger_archived
          end
        end
      RUBY
      plain = wisper.sub("  include Wisper::Publisher\n", '')

      expect(effects(wisper)['close!'][:events_published]).to eq(%w[ledger_archived ledger_closed])
      expect(effects(plain)).to be_nil
    end

    it 'names each HTTP client once, sorted' do
      source = <<~RUBY
        class Ledger
          def sync
            Net::HTTP.get(uri)
            HTTParty.get(url)
            RestClient.post(url, body)
            Faraday.new(url: base).get('/a')
            Net::HTTP.post(uri, body)
          end
        end
      RUBY

      expect(effects(source)['sync'][:external_calls]).to eq(%w[Faraday HTTParty Net::HTTP RestClient])
    end

    it 'ignores an instrument call whose event name is not a literal' do
      source = <<~RUBY
        class Ledger
          def emit(name)
            ActiveSupport::Notifications.instrument(name)
          end
        end
      RUBY

      expect(effects(source)).to be_nil
    end
  end

  describe 'visibility' do
    let(:source) do
      <<~RUBY
        class Ledger
          def open_method
            OpenJob.perform_later
          end

          def later_hidden
            HiddenJob.perform_later
          end
          private :later_hidden

          private def inline_hidden
            InlineJob.perform_later
          end

          def initialize
            BootJob.perform_later
          end

          protected

          def guarded
            GuardedJob.perform_later
          end

          private

          def hidden
            SecretJob.perform_later
          end

          public

          def reopened
            ReopenedJob.perform_later
          end
        end
      RUBY
    end

    it 'records public methods only' do
      expect(effects(source).keys).to eq(%w[open_method reopened])
    end
  end

  describe 'class methods' do
    let(:source) do
      <<~RUBY
        class Ledger
          def self.rebuild
            RebuildJob.perform_later
          end

          def self.internal
            InternalJob.perform_later
          end
          private_class_method :internal

          class << self
            def sweep
              SweepJob.perform_later
            end

            private

            def hidden_sweep
              HiddenSweepJob.perform_later
            end
          end

          def rebuild
            InstanceJob.perform_later
          end
        end
      RUBY
    end

    it 'keys class methods with a self. prefix, apart from instance methods' do
      recorded = effects(source)

      expect(recorded.keys).to eq(%w[self.rebuild self.sweep rebuild])
      expect(recorded['self.rebuild'][:jobs_enqueued]).to eq(['RebuildJob'])
      expect(recorded['rebuild'][:jobs_enqueued]).to eq(['InstanceJob'])
    end

    it 'does not claim singleton methods defined on another object' do
      source = <<~RUBY
        class Ledger
          class << OTHER_OBJECT
            def dispatch
              ForeignJob.perform_later
            end
          end
          class << self
            def own_dispatch
              OwnJob.perform_later
            end
          end
        end
      RUBY

      expect(effects(source).keys).to eq(['self.own_dispatch'])
      expect(effects(source)['self.own_dispatch'][:jobs_enqueued]).to eq(['OwnJob'])
    end

    it 'honors public_class_method after private_class_method' do
      source = <<~RUBY
        class Ledger
          def self.dispatch
            DispatchJob.perform_later
          end
          private_class_method :dispatch
          public_class_method :dispatch
        end
      RUBY

      expect(effects(source).keys).to eq(['self.dispatch'])
    end
  end

  describe 'which class is read' do
    let(:source) do
      <<~RUBY
        module Billing
          class Ledger
            def post!
              PostJob.perform_later
            end

            class Entry
              def void!
                VoidJob.perform_later
              end
            end
          end

          class Helper
            def assist
              AssistJob.perform_later
            end
          end
        end
      RUBY
    end

    it 'reads only the methods of the unit class' do
      expect(effects(source, identifier: 'Billing::Ledger').keys).to eq(['post!'])
      expect(effects(source, identifier: 'Billing::Ledger::Entry').keys).to eq(['void!'])
    end

    it 'matches a class by the tail of the identifier when the source is an excerpt' do
      excerpt = "class Entry\n  def void!\n    VoidJob.perform_later\n  end\nend\n"

      expect(effects(excerpt, identifier: 'Billing::Ledger::Entry').keys).to eq(['void!'])
    end

    it 'merges a class reopened in the same file' do
      source = <<~RUBY
        class Ledger
          def one
            OneJob.perform_later
          end
        end

        class Ledger
          def two
            TwoJob.perform_later
          end
        end
      RUBY

      expect(effects(source).keys).to eq(%w[one two])
    end

    it 'skips the named methods' do
      source = <<~RUBY
        class Ledger
          def index
            IndexJob.perform_later
          end

          def helper
            HelperJob.perform_later
          end
        end
      RUBY

      expect(effects(source, skip: ['index']).keys).to eq(['helper'])
    end
  end

  describe 'lexical resolution' do
    before do
      stub_const('Billing', Module.new)
      stub_const('Billing::Ledger', Class.new)
      stub_const('Billing::PostJob', Class.new)
      stub_const('Billing::TallyService', Class.new)
      stub_const('Billing::ReceiptMailer', Class.new)
    end

    it 'names jobs, services and mailers the way Ruby resolves them in the class' do
      source = <<~RUBY
        module Billing
          class Ledger
            def post!
              PostJob.perform_later
              TallyService.call
              ReceiptMailer.posted.deliver_later
              ::TallyService.call
            end
          end
        end
      RUBY

      expect(effects(source, identifier: 'Billing::Ledger')['post!']).to include(
        jobs_enqueued: ['Billing::PostJob'],
        services_called: ['Billing::TallyService', 'TallyService'],
        mail_sent: ['Billing::ReceiptMailer']
      )
    end
  end

  describe 'same-class calls' do
    it 'does not follow same-named methods inside foreign eval or exec blocks' do
      source = <<~RUBY
        class Ledger
          def dispatch(other)
            other.instance_eval { deliver }
            other.instance_exec { deliver }
            other.class_eval { deliver }
            other.class_exec { deliver }
            other.module_eval { deliver }
            other.module_exec { deliver }
          end
          private
          def deliver
            WrongJob.perform_later
          end
        end
      RUBY

      expect(effects(source)).to be_nil
    end

    it 'keeps following calls inside ordinary and self eval blocks' do
      source = <<~RUBY
        class Ledger
          def dispatch(other)
            other.tap { deliver }
            self.instance_eval { deliver }
          end
          private
          def deliver
            RightJob.perform_later
          end
        end
      RUBY

      expect(effects(source)['dispatch'][:via_method]).to eq('deliver' => { jobs_enqueued: ['RightJob'] })
    end

    it 'lists the effects of a called method under via_method' do
      source = <<~RUBY
        class Ledger
          def refund!
            DirectJob.perform_later
            notify
          end

          private

          def notify
            ReceiptMailer.refunded(self).deliver_later
            log_it
          end

          def log_it
            AuditService.call(self)
          end
        end
      RUBY

      expect(effects(source)).to eq(
        'refund!' => {
          analysis_status: 'analyzed', jobs_enqueued: ['DirectJob'], mail_sent: [], services_called: [],
          columns_written: [], events_published: [], external_calls: [],
          via_method: {
            'log_it' => { services_called: ['AuditService'] },
            'notify' => { mail_sent: ['ReceiptMailer'] }
          }
        }
      )
    end

    it 'records a method whose only effects come through another method' do
      source = <<~RUBY
        class Ledger
          def close!
            self.finish
          end

          def finish
            CloseJob.perform_later
          end
        end
      RUBY

      recorded = effects(source)

      expect(recorded['close!'][:jobs_enqueued]).to eq([])
      expect(recorded['close!'][:via_method]).to eq('finish' => { jobs_enqueued: ['CloseJob'] })
      expect(recorded['finish']).not_to have_key(:via_method)
    end

    it 'guards cycles' do
      source = <<~RUBY
        class Ledger
          def ping
            PingJob.perform_later
            pong
          end

          def pong
            PongJob.perform_later
            ping
          end
        end
      RUBY

      recorded = effects(source)

      expect(recorded['ping'][:via_method]).to eq('pong' => { jobs_enqueued: ['PongJob'] })
      expect(recorded['pong'][:via_method]).to eq('ping' => { jobs_enqueued: ['PingJob'] })
    end

    it 'stops three calls deep' do
      source = <<~RUBY
        class Ledger
          def start
            one
          end

          private

          def one
            OneJob.perform_later
            two
          end

          def two
            TwoJob.perform_later
            three
          end

          def three
            ThreeJob.perform_later
            four
          end

          def four
            FourJob.perform_later
          end
        end
      RUBY

      expect(effects(source)['start'][:via_method].keys).to eq(%w[one three two])
    end

    it 'follows class methods to class methods and instance methods to instance methods' do
      source = <<~RUBY
        class Ledger
          def self.sweep
            purge
          end

          def self.purge
            PurgeJob.perform_later
          end

          def purge
            InstanceJob.perform_later
          end

          def tidy
            purge
          end
        end
      RUBY

      recorded = effects(source)

      expect(recorded['self.sweep'][:via_method]).to eq('self.purge' => { jobs_enqueued: ['PurgeJob'] })
      expect(recorded['tidy'][:via_method]).to eq('purge' => { jobs_enqueued: ['InstanceJob'] })
    end
  end

  describe 'the per-unit cap' do
    let(:source) do
      methods = (1..5).map { |n| "  def m#{n}\n    Step#{n}Job.perform_later\n  end\n" }.join("\n")
      "class Ledger\n#{methods}end\n"
    end

    it 'keeps the first methods in source order and flags the truncation' do
      unit = apply(source, limit: 3)

      expect(unit.metadata[:method_effects].keys).to eq(%w[m1 m2 m3])
      expect(unit.metadata[:method_effects_truncated]).to be(true)
    end

    it 'sets no flag under the cap' do
      unit = apply(source, limit: 5)

      expect(unit.metadata[:method_effects].size).to eq(5)
      expect(unit.metadata).not_to have_key(:method_effects_truncated)
    end

    it 'defaults to the configured limit' do
      allow(Woods.configuration).to receive(:method_effects_limit).and_return(2)

      expect(apply(source).metadata[:method_effects].keys).to eq(%w[m1 m2])
    end

    it 'falls back to 50 when Woods is not configured' do
      allow(Woods).to receive(:configuration).and_return(nil)

      expect(described_class.default_limit).to eq(50)
      expect(apply(source).metadata[:method_effects].size).to eq(5)
    end

    it 'records every method when the limit is nil' do
      expect(apply(source, limit: nil).metadata[:method_effects].size).to eq(5)
    end
  end

  describe 'edges' do
    it 'does not annotate a structural inheritance edge to a called mailer' do
      source = <<~RUBY
        class Ledger
          def notify
            ParentMailer.receipt.deliver_later
          end
        end
      RUBY
      dependencies = [
        { type: :mailer, target: 'ParentMailer', via: :inheritance },
        { type: :mailer, target: 'ParentMailer', via: :code_reference }
      ]
      unit = apply(source, dependencies: dependencies)

      expect(unit.dependencies.first).not_to have_key(:through)
      expect(unit.dependencies.last[:through]).to eq('notify')
    end

    let(:source) do
      <<~RUBY
        class Ledger
          def refund!
            RefundJob.perform_later
            ReceiptMailer.refunded(self).deliver_later
            notify
          end

          def capture!
            RefundJob.perform_later
          end

          after_commit { OrphanJob.perform_later }

          private

          def notify
            TallyService.call
          end
        end
      RUBY
    end

    let(:dependencies) do
      [
        { type: :model, target: 'Account', via: :belongs_to },
        { type: :job, target: 'RefundJob', via: :code_reference },
        { type: :job, target: 'RefundJob', via: :job_enqueue },
        { type: :job, target: 'OrphanJob', via: :job_enqueue },
        { type: :mailer, target: 'ReceiptMailer', via: :code_reference },
        { type: :service, target: 'TallyService', via: :code_reference }
      ]
    end

    it 'names the public methods that reach each job, mailer and service edge' do
      unit = apply(source, dependencies: dependencies)

      expect(unit.dependencies).to eq(
        [
          { type: :model, target: 'Account', via: :belongs_to },
          { type: :job, target: 'RefundJob', via: :code_reference },
          { type: :job, target: 'RefundJob', via: :job_enqueue, through: 'capture!, refund!' },
          { type: :job, target: 'OrphanJob', via: :job_enqueue },
          { type: :mailer, target: 'ReceiptMailer', via: :code_reference, through: 'refund!' },
          { type: :service, target: 'TallyService', via: :code_reference, through: 'refund!' }
        ]
      )
    end

    it 'names every reaching method even when the metadata is capped' do
      unit = apply(source, dependencies: dependencies, limit: 1)

      expect(unit.metadata[:method_effects].keys).to eq(['refund!'])
      expect(unit.dependencies[2][:through]).to eq('capture!, refund!')
    end
  end
end
