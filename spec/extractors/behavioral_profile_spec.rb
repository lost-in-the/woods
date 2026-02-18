# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extractors/behavioral_profile'

RSpec.describe CodebaseIndex::Extractors::BehavioralProfile do
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }
  let(:rails_root) { Pathname.new('/fake/app') }
  let(:rails_app) { double('RailsApp') }
  let(:rails_config) { double('RailsConfig') }

  before do
    stub_const('Rails', double('Rails',
                               root: rails_root,
                               logger: logger,
                               version: '7.1.3',
                               application: rails_app))
    allow(rails_app).to receive(:config).and_return(rails_config)

    # Default: nothing is configured
    allow(rails_config).to receive(:respond_to?).and_return(false)
    stub_const('RUBY_VERSION', '3.2.2')
  end

  describe '#extract' do
    it 'returns an ExtractedUnit' do
      unit = described_class.new.extract
      expect(unit).to be_a(CodebaseIndex::ExtractedUnit)
    end

    it 'sets type to :configuration' do
      unit = described_class.new.extract
      expect(unit.type).to eq(:configuration)
    end

    it 'sets identifier to BehavioralProfile' do
      unit = described_class.new.extract
      expect(unit.identifier).to eq('BehavioralProfile')
    end

    it 'sets file_path to config/application.rb' do
      unit = described_class.new.extract
      expect(unit.file_path).to eq('/fake/app/config/application.rb')
    end

    it 'sets namespace to behavioral_profile' do
      unit = described_class.new.extract
      expect(unit.namespace).to eq('behavioral_profile')
    end

    it 'includes rails_version in metadata' do
      unit = described_class.new.extract
      expect(unit.metadata[:rails_version]).to eq('7.1.3')
    end

    it 'includes ruby_version in metadata' do
      unit = described_class.new.extract
      expect(unit.metadata[:ruby_version]).to eq('3.2.2')
    end

    it 'includes config_type in metadata' do
      unit = described_class.new.extract
      expect(unit.metadata[:config_type]).to eq('behavioral_profile')
    end

    it 'generates a human-readable source_code summary' do
      unit = described_class.new.extract
      expect(unit.source_code).to include('Behavioral Profile')
      expect(unit.source_code).to include('Rails 7.1.3')
      expect(unit.source_code).to include('Ruby 3.2.2')
    end
  end

  # ── Database section ─────────────────────────────────────────────────

  describe 'database extraction' do
    context 'when ActiveRecord is available with connection_db_config' do
      let(:db_config) { double('DatabaseConfig', adapter: 'postgresql') }
      let(:ar_base) { double('ARBase') }

      before do
        stub_const('ActiveRecord::Base', ar_base)
        allow(ar_base).to receive(:connection_db_config).and_return(db_config)
        allow(ar_base).to receive(:respond_to?).with(:connection_db_config).and_return(true)
        allow(rails_config).to receive(:respond_to?).with(:active_record).and_return(true)
        ar_config = double('ARConfig')
        allow(rails_config).to receive(:active_record).and_return(ar_config)
        allow(ar_config).to receive(:respond_to?).with(:schema_format).and_return(true)
        allow(ar_config).to receive(:schema_format).and_return(:ruby)
        allow(ar_config).to receive(:respond_to?).with(:belongs_to_required_by_default).and_return(true)
        allow(ar_config).to receive(:belongs_to_required_by_default).and_return(true)
        allow(ar_config).to receive(:respond_to?).with(:has_many_inversing).and_return(true)
        allow(ar_config).to receive(:has_many_inversing).and_return(true)
      end

      it 'extracts database adapter' do
        unit = described_class.new.extract
        expect(unit.metadata[:database][:adapter]).to eq('postgresql')
      end

      it 'extracts schema_format' do
        unit = described_class.new.extract
        expect(unit.metadata[:database][:schema_format]).to eq(:ruby)
      end

      it 'extracts belongs_to_required_by_default' do
        unit = described_class.new.extract
        expect(unit.metadata[:database][:belongs_to_required_by_default]).to eq(true)
      end

      it 'extracts has_many_inversing' do
        unit = described_class.new.extract
        expect(unit.metadata[:database][:has_many_inversing]).to eq(true)
      end

      it 'includes adapter in source_code narrative' do
        unit = described_class.new.extract
        expect(unit.source_code).to include('postgresql')
      end
    end

    context 'when ActiveRecord is not defined' do
      it 'returns empty database section' do
        unit = described_class.new.extract
        expect(unit.metadata[:database]).to eq({})
      end
    end
  end

  # ── Frameworks section ───────────────────────────────────────────────

  describe 'frameworks extraction' do
    context 'when ActionCable is defined' do
      before { stub_const('ActionCable', Module.new) }

      it 'detects ActionCable as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:action_cable]).to eq(true)
      end
    end

    context 'when ActiveStorage is defined' do
      before { stub_const('ActiveStorage', Module.new) }

      it 'detects ActiveStorage as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:active_storage]).to eq(true)
      end
    end

    context 'when ActionMailbox is defined' do
      before { stub_const('ActionMailbox', Module.new) }

      it 'detects ActionMailbox as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:action_mailbox]).to eq(true)
      end
    end

    context 'when ActionText is defined' do
      before { stub_const('ActionText', Module.new) }

      it 'detects ActionText as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:action_text]).to eq(true)
      end
    end

    context 'when Turbo is defined' do
      before { stub_const('Turbo', Module.new) }

      it 'detects Turbo as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:turbo]).to eq(true)
      end
    end

    context 'when StimulusReflex is defined' do
      before { stub_const('StimulusReflex', Module.new) }

      it 'detects StimulusReflex as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:stimulus_reflex]).to eq(true)
      end
    end

    context 'when SolidQueue is defined' do
      before { stub_const('SolidQueue', Module.new) }

      it 'detects SolidQueue as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:solid_queue]).to eq(true)
      end
    end

    context 'when SolidCache is defined' do
      before { stub_const('SolidCache', Module.new) }

      it 'detects SolidCache as active' do
        unit = described_class.new.extract
        expect(unit.metadata[:frameworks_active][:solid_cache]).to eq(true)
      end
    end

    context 'when no optional frameworks are loaded' do
      it 'marks all frameworks as false' do
        unit = described_class.new.extract
        frameworks = unit.metadata[:frameworks_active]
        expect(frameworks.values).to all(eq(false))
      end
    end

    it 'includes detected frameworks in source_code narrative' do
      stub_const('Turbo', Module.new)
      stub_const('ActionCable', Module.new)

      unit = described_class.new.extract
      expect(unit.source_code).to include('Turbo')
      expect(unit.source_code).to include('ActionCable')
    end
  end

  # ── Behavior flags section ──────────────────────────────────────────

  describe 'behavior flags extraction' do
    context 'when api_only is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:api_only).and_return(true)
        allow(rails_config).to receive(:api_only).and_return(true)
      end

      it 'extracts api_only flag' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags][:api_only]).to eq(true)
      end
    end

    context 'when eager_load is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:eager_load).and_return(true)
        allow(rails_config).to receive(:eager_load).and_return(false)
      end

      it 'extracts eager_load flag' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags][:eager_load]).to eq(false)
      end
    end

    context 'when time_zone is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:time_zone).and_return(true)
        allow(rails_config).to receive(:time_zone).and_return('Eastern Time (US & Canada)')
      end

      it 'extracts time_zone' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags][:time_zone]).to eq('Eastern Time (US & Canada)')
      end
    end

    context 'when session_store is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:session_store).and_return(true)
        allow(rails_config).to receive(:session_store).and_return(:cookie_store)
      end

      it 'extracts session_store' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags][:session_store]).to eq(:cookie_store)
      end
    end

    context 'when filter_parameters is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:filter_parameters).and_return(true)
        allow(rails_config).to receive(:filter_parameters).and_return(%i[password token])
      end

      it 'extracts filter_parameters' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags][:filter_parameters]).to eq(%i[password token])
      end
    end

    context 'when action_controller is configured' do
      before do
        ac_config = double('ACConfig')
        allow(rails_config).to receive(:respond_to?).with(:action_controller).and_return(true)
        allow(rails_config).to receive(:action_controller).and_return(ac_config)
        allow(ac_config).to receive(:respond_to?).with(:action_on_unpermitted_parameters).and_return(true)
        allow(ac_config).to receive(:action_on_unpermitted_parameters).and_return(:log)
      end

      it 'extracts action_on_unpermitted_parameters' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags][:action_on_unpermitted_parameters]).to eq(:log)
      end
    end

    context 'when no behavior flags are configured' do
      it 'returns empty hash for behavior_flags' do
        unit = described_class.new.extract
        expect(unit.metadata[:behavior_flags]).to eq({})
      end
    end
  end

  # ── Background processing section ──────────────────────────────────

  describe 'background processing extraction' do
    context 'when active_job queue_adapter is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:active_job).and_return(true)
        aj_config = double('AJConfig')
        allow(rails_config).to receive(:active_job).and_return(aj_config)
        allow(aj_config).to receive(:respond_to?).with(:queue_adapter).and_return(true)
        allow(aj_config).to receive(:queue_adapter).and_return(:sidekiq)
      end

      it 'extracts queue_adapter' do
        unit = described_class.new.extract
        expect(unit.metadata[:background_processing][:adapter]).to eq(:sidekiq)
      end
    end

    context 'when active_job is not configured' do
      it 'returns empty hash for background_processing' do
        unit = described_class.new.extract
        expect(unit.metadata[:background_processing]).to eq({})
      end
    end
  end

  # ── Caching section ────────────────────────────────────────────────

  describe 'caching extraction' do
    context 'when cache_store is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:cache_store).and_return(true)
        allow(rails_config).to receive(:cache_store).and_return(:redis_cache_store)
      end

      it 'extracts cache_store' do
        unit = described_class.new.extract
        expect(unit.metadata[:caching][:store]).to eq(:redis_cache_store)
      end
    end

    context 'when cache_store returns an array (store + options)' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:cache_store).and_return(true)
        allow(rails_config).to receive(:cache_store).and_return([:redis_cache_store, { url: 'redis://localhost' }])
      end

      it 'extracts the store name from the array' do
        unit = described_class.new.extract
        expect(unit.metadata[:caching][:store]).to eq(:redis_cache_store)
      end
    end

    context 'when cache_store is not configured' do
      it 'returns empty hash for caching' do
        unit = described_class.new.extract
        expect(unit.metadata[:caching]).to eq({})
      end
    end
  end

  # ── Email section ──────────────────────────────────────────────────

  describe 'email extraction' do
    context 'when action_mailer is configured' do
      before do
        allow(rails_config).to receive(:respond_to?).with(:action_mailer).and_return(true)
        am_config = double('AMConfig')
        allow(rails_config).to receive(:action_mailer).and_return(am_config)
        allow(am_config).to receive(:respond_to?).with(:delivery_method).and_return(true)
        allow(am_config).to receive(:delivery_method).and_return(:smtp)
      end

      it 'extracts delivery_method' do
        unit = described_class.new.extract
        expect(unit.metadata[:email][:delivery_method]).to eq(:smtp)
      end
    end

    context 'when action_mailer is not configured' do
      it 'returns empty hash for email' do
        unit = described_class.new.extract
        expect(unit.metadata[:email]).to eq({})
      end
    end
  end

  # ── Dependencies ───────────────────────────────────────────────────

  describe 'dependencies' do
    it 'all dependencies have :via key' do
      stub_const('Turbo', Module.new)
      stub_const('SolidQueue', Module.new)

      unit = described_class.new.extract
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'includes detected frameworks as dependencies' do
      stub_const('Turbo', Module.new)
      stub_const('ActiveStorage', Module.new)

      unit = described_class.new.extract
      targets = unit.dependencies.map { |d| d[:target] }
      expect(targets).to include('Turbo')
      expect(targets).to include('ActiveStorage')
    end
  end

  # ── Graceful failure ───────────────────────────────────────────────

  describe 'graceful failure' do
    it 'still produces a unit when one section raises' do
      allow(rails_config).to receive(:respond_to?).with(:cache_store).and_raise(StandardError, 'boom')

      unit = described_class.new.extract
      expect(unit).to be_a(CodebaseIndex::ExtractedUnit)
      expect(unit.metadata[:database]).to eq({})
    end

    it 'returns nil when entire extraction fails' do
      allow(Rails).to receive(:application).and_raise(StandardError, 'catastrophe')

      unit = described_class.new.extract
      expect(unit).to be_nil
    end
  end
end
