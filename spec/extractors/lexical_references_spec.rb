# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/reference_patterns'
require 'woods/extractors/shared_dependency_scanner'

# A bare constant at a call site means what Ruby's lexical lookup makes of it:
# each enclosing class or module (innermost first, Module.nesting), then the
# innermost one's ancestors, then the top level. `PingJob.perform_in` inside
# `class Shipment` is `Shipment::PingJob` when that exists.
RSpec.describe 'Lexically scoped references' do
  def enqueues(source)
    Woods::Extractors::ReferencePatterns.job_enqueues(source)
  end

  def define(name)
    stub_const(name, Class.new)
  end

  let(:in_shipment) do
    <<~RUBY
      class Shipment
        def dispatch
          PingJob.perform_in(5, id)
        end
      end
    RUBY
  end

  it 'resolves an enqueue to the job nested in the enclosing class' do
    define('Shipment')
    define('Shipment::PingJob')

    expect(enqueues(in_shipment)).to eq(['Shipment::PingJob'])
  end

  it 'keeps the top-level job when the enclosing class has no nested one' do
    define('Shipment')
    define('PingJob')

    expect(enqueues(in_shipment)).to eq(['PingJob'])
  end

  it 'prefers the innermost enclosing scope' do
    define('Fleet')
    define('Fleet::Shipment')
    define('Fleet::PingJob')
    define('Fleet::Shipment::PingJob')

    expect(enqueues("module Fleet\n#{in_shipment}end\n")).to eq(['Fleet::Shipment::PingJob'])
  end

  it 'looks outward through the enclosing modules' do
    define('Fleet')
    define('Fleet::Shipment')
    define('Fleet::PingJob')
    define('PingJob')

    expect(enqueues("module Fleet\n#{in_shipment}end\n")).to eq(['Fleet::PingJob'])
  end

  it 'does not look through a compact declaration’s namespace' do
    define('Fleet')
    define('Fleet::Shipment')
    define('Fleet::PingJob')
    define('PingJob')
    source = in_shipment.sub('class Shipment', 'class Fleet::Shipment')

    expect(enqueues(source)).to eq(['PingJob'])
  end

  it 'falls back to the enclosing class’s ancestors' do
    stub_const('Dispatchable', Class.new)
    define('Dispatchable::PingJob')
    stub_const('Shipment', Class.new(Dispatchable))

    expect(enqueues(in_shipment)).to eq(['Dispatchable::PingJob'])
  end

  it 'resolves a qualified reference from its first segment' do
    define('Fleet')
    define('Fleet::Tasks')
    define('Fleet::Tasks::PingJob')
    define('Fleet::Shipment')
    source = "module Fleet\n#{in_shipment.sub('PingJob.', 'Tasks::PingJob.')}end\n"

    expect(enqueues(source)).to eq(['Fleet::Tasks::PingJob'])
  end

  it 'keeps an explicitly top-level reference top-level' do
    define('Shipment')
    define('Shipment::PingJob')
    define('PingJob')

    expect(enqueues(in_shipment.sub('PingJob.', '::PingJob.'))).to eq(['PingJob'])
  end

  it 'uses the nesting at each call site' do
    define('Shipment')
    define('Shipment::PingJob')
    define('Invoice')
    define('Invoice::PingJob')
    source = "#{in_shipment}#{in_shipment.gsub('Shipment', 'Invoice')}"

    expect(enqueues(source)).to eq(%w[Shipment::PingJob Invoice::PingJob])
  end

  it 'keeps the written name when no candidate is a loaded constant' do
    expect(enqueues(in_shipment)).to eq(['PingJob'])
  end

  it 'keeps the written name outside any class or module' do
    define('PingJob')

    expect(enqueues("PingJob.perform_later\n")).to eq(['PingJob'])
  end

  it 'counts character positions after multibyte text' do
    define('Shipment')
    define('Shipment::PingJob')
    define('Invoice')

    source = "# Envío — señal\n#{in_shipment}class Invoice\n  def x\n    PingJob.perform_later\n  end\nend\n"

    expect(enqueues(source)).to eq(%w[Shipment::PingJob PingJob])
  end

  it 'keeps the written names when the source does not parse' do
    define('Shipment')
    define('Shipment::PingJob')

    expect(enqueues("class Shipment\n  def x\n    PingJob.perform_later(\n")).to eq(['PingJob'])
  end

  describe 'complexity' do
    budget_seconds = 1.0

    around do |example|
      if Regexp.respond_to?(:timeout=)
        previous = Regexp.timeout
        Regexp.timeout = budget_seconds
        begin
          example.run
        ensure
          Regexp.timeout = previous
        end
      else
        Timeout.timeout(budget_seconds * 5) { example.run }
      end
    end

    it 'stays linear over many sibling classes that each enqueue' do
      source = Array.new(10_000) { |i| "class Shipment#{i}\n  def x\n    PingJob.perform_later\n  end\nend\n" }.join
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(enqueues(source).size).to eq(10_000)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < budget_seconds * 5
    end

    it 'stays linear under deep nesting' do
      depth = 1_000
      source = "#{"module M\n" * depth}#{"PingJob.perform_later\n" * 1_000}#{"end\n" * depth}"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(enqueues(source).size).to eq(1_000)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < budget_seconds * 5
    end
  end

  describe 'through the shared scanner' do
    subject(:scanner) { Class.new { include Woods::Extractors::SharedDependencyScanner }.new }

    before do
      define('Billing')
      define('Billing::ChargeService')
      define('Billing::ReceiptMailer')
      define('Billing::Shipment')
      define('Billing::Shipment::PingJob')
    end

    let(:source) do
      <<~RUBY
        module Billing
          class Shipment
            def settle
              ChargeService.call(self)
              ReceiptMailer.paid(self).deliver_later
              PingJob.perform_in(5, id)
            end
          end
        end
      RUBY
    end

    it 'records the resolved job as the edge target' do
      expect(scanner.scan_job_dependencies(source).map { |d| d[:target] }).to eq(['Billing::Shipment::PingJob'])
    end

    it 'records the resolved service as the edge target' do
      expect(scanner.scan_service_dependencies(source).map { |d| d[:target] }).to eq(['Billing::ChargeService'])
    end

    it 'records the resolved mailer as the edge target' do
      expect(scanner.scan_mailer_dependencies(source).map { |d| d[:target] }).to eq(['Billing::ReceiptMailer'])
    end
  end
end
