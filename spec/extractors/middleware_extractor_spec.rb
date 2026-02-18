# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/middleware_extractor'

RSpec.describe CodebaseIndex::Extractors::MiddlewareExtractor do
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }

  def build_middleware(name:, args: [])
    double('Middleware', name: name, args: args, to_s: name)
  end

  # ── No middleware available ──────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing Rails middleware gracefully' do
      stub_const('Rails', double('Rails', logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(false)

      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    let(:middlewares) do
      [
        build_middleware(name: 'ActionDispatch::HostAuthorization'),
        build_middleware(name: 'Rack::Sendfile'),
        build_middleware(name: 'ActionDispatch::Executor'),
        build_middleware(name: 'Rack::Runtime', args: ['X-Runtime'])
      ]
    end

    before do
      stack = double('MiddlewareStack')
      allow(stack).to receive(:each).and_yield(middlewares[0])
                                    .and_yield(middlewares[1])
                                    .and_yield(middlewares[2])
                                    .and_yield(middlewares[3])
      application = double('Application', middleware: stack)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'returns a single unit for the middleware stack' do
      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('MiddlewareStack')
      expect(units.first.type).to eq(:middleware)
    end

    it 'sets file_path to nil (runtime introspection)' do
      unit = described_class.new.extract_all.first
      expect(unit.file_path).to be_nil
    end
  end

  # ── Metadata ────────────────────────────────────────────────────────

  describe 'metadata' do
    let(:middlewares) do
      [
        build_middleware(name: 'ActionDispatch::HostAuthorization'),
        build_middleware(name: 'Rack::Sendfile'),
        build_middleware(name: 'Rack::Runtime', args: ['X-Runtime'])
      ]
    end

    before do
      stack = double('MiddlewareStack')
      allow(stack).to receive(:each).and_yield(middlewares[0])
                                    .and_yield(middlewares[1])
                                    .and_yield(middlewares[2])
      application = double('Application', middleware: stack)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'counts middleware entries' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:middleware_count]).to eq(3)
    end

    it 'lists middleware names' do
      unit = described_class.new.extract_all.first
      expect(unit.metadata[:middleware_list]).to eq([
                                                      'ActionDispatch::HostAuthorization',
                                                      'Rack::Sendfile',
                                                      'Rack::Runtime'
                                                    ])
    end

    it 'includes middleware details with position and args' do
      unit = described_class.new.extract_all.first
      details = unit.metadata[:middleware_details]

      expect(details[0][:position]).to eq(0)
      expect(details[0][:name]).to eq('ActionDispatch::HostAuthorization')
      expect(details[2][:args]).to eq(['X-Runtime'])
    end
  end

  # ── Source code ──────────────────────────────────────────────────────

  describe 'source code' do
    let(:middlewares) do
      [
        build_middleware(name: 'Rack::Sendfile'),
        build_middleware(name: 'Rack::Runtime', args: ['X-Runtime'])
      ]
    end

    before do
      stack = double('MiddlewareStack')
      allow(stack).to receive(:each).and_yield(middlewares[0])
                                    .and_yield(middlewares[1])
      application = double('Application', middleware: stack)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'builds readable source with positions' do
      unit = described_class.new.extract_all.first
      expect(unit.source_code).to include('Rack Middleware Stack')
      expect(unit.source_code).to include('[0] Rack::Sendfile')
      expect(unit.source_code).to include('[1] Rack::Runtime (X-Runtime)')
    end
  end

  # ── Dependencies ────────────────────────────────────────────────────

  describe 'dependencies' do
    let(:middlewares) { [build_middleware(name: 'Rack::Sendfile')] }

    before do
      stack = double('MiddlewareStack')
      allow(stack).to receive(:each).and_yield(middlewares[0])
      application = double('Application', middleware: stack)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'has empty dependencies' do
      unit = described_class.new.extract_all.first
      expect(unit.dependencies).to eq([])
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────

  describe 'edge cases' do
    it 'returns empty array when stack is empty' do
      stack = double('MiddlewareStack')
      allow(stack).to receive(:each)
      application = double('Application', middleware: stack)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'handles middleware with klass instead of name' do
      klass_middleware = double('Middleware', klass: 'CustomMiddleware', args: [], to_s: 'CustomMiddleware')
      allow(klass_middleware).to receive(:respond_to?).with(:name).and_return(false)
      allow(klass_middleware).to receive(:respond_to?).with(:klass).and_return(true)
      allow(klass_middleware).to receive(:respond_to?).with(:args).and_return(true)

      stack = double('MiddlewareStack')
      allow(stack).to receive(:each).and_yield(klass_middleware)
      application = double('Application', middleware: stack)
      stub_const('Rails', double('Rails', application: application, logger: logger))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.metadata[:middleware_list]).to eq(['CustomMiddleware'])
    end
  end
end
