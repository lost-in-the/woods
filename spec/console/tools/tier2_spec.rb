# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/tools/tier2'

RSpec.describe CodebaseIndex::Console::Tools::Tier2 do
  describe '.console_diagnose_model' do
    it 'builds a diagnose_model request' do
      result = described_class.console_diagnose_model(model: 'User')
      expect(result[:tool]).to eq('diagnose_model')
      expect(result[:params][:model]).to eq('User')
    end

    it 'includes scope when provided' do
      result = described_class.console_diagnose_model(model: 'User', scope: { active: true })
      expect(result[:params][:scope]).to eq({ active: true })
    end

    it 'includes sample_size when provided' do
      result = described_class.console_diagnose_model(model: 'User', sample_size: 10)
      expect(result[:params][:sample_size]).to eq(10)
    end

    it 'caps sample_size at 25' do
      result = described_class.console_diagnose_model(model: 'User', sample_size: 100)
      expect(result[:params][:sample_size]).to eq(25)
    end
  end

  describe '.console_data_snapshot' do
    it 'builds a data_snapshot request' do
      result = described_class.console_data_snapshot(model: 'User', id: 42)
      expect(result[:tool]).to eq('data_snapshot')
      expect(result[:params][:model]).to eq('User')
      expect(result[:params][:id]).to eq(42)
    end

    it 'includes associations when provided' do
      result = described_class.console_data_snapshot(model: 'User', id: 1, associations: %w[posts comments])
      expect(result[:params][:associations]).to eq(%w[posts comments])
    end

    it 'includes depth when provided' do
      result = described_class.console_data_snapshot(model: 'User', id: 1, depth: 2)
      expect(result[:params][:depth]).to eq(2)
    end

    it 'caps depth at 3' do
      result = described_class.console_data_snapshot(model: 'User', id: 1, depth: 10)
      expect(result[:params][:depth]).to eq(3)
    end
  end

  describe '.console_validate_record' do
    it 'builds a validate_record request' do
      result = described_class.console_validate_record(model: 'User', id: 42)
      expect(result[:tool]).to eq('validate_record')
      expect(result[:params][:model]).to eq('User')
      expect(result[:params][:id]).to eq(42)
    end

    it 'validates with specific attributes' do
      result = described_class.console_validate_record(model: 'User', id: 1, attributes: { email: 'bad' })
      expect(result[:params][:attributes]).to eq({ email: 'bad' })
    end
  end

  describe '.console_check_setting' do
    it 'builds a check_setting request' do
      result = described_class.console_check_setting(key: 'feature.enabled')
      expect(result[:tool]).to eq('check_setting')
      expect(result[:params][:key]).to eq('feature.enabled')
    end

    it 'includes namespace when provided' do
      result = described_class.console_check_setting(key: 'theme', namespace: 'ui')
      expect(result[:params][:namespace]).to eq('ui')
    end
  end

  describe '.console_update_setting' do
    it 'builds an update_setting request with confirmation flag' do
      result = described_class.console_update_setting(key: 'feature.enabled', value: true)
      expect(result[:tool]).to eq('update_setting')
      expect(result[:params][:key]).to eq('feature.enabled')
      expect(result[:params][:value]).to be true
      expect(result[:requires_confirmation]).to be true
    end

    it 'includes namespace when provided' do
      result = described_class.console_update_setting(key: 'theme', value: 'dark', namespace: 'ui')
      expect(result[:params][:namespace]).to eq('ui')
    end
  end

  describe '.console_check_policy' do
    it 'builds a check_policy request' do
      result = described_class.console_check_policy(model: 'Post', id: 1, user_id: 42, action: 'update')
      expect(result[:tool]).to eq('check_policy')
      expect(result[:params][:model]).to eq('Post')
      expect(result[:params][:id]).to eq(1)
      expect(result[:params][:user_id]).to eq(42)
      expect(result[:params][:action]).to eq('update')
    end
  end

  describe '.console_validate_with' do
    it 'builds a validate_with request' do
      result = described_class.console_validate_with(model: 'User', attributes: { email: 'test@example.com' })
      expect(result[:tool]).to eq('validate_with')
      expect(result[:params][:model]).to eq('User')
      expect(result[:params][:attributes]).to eq({ email: 'test@example.com' })
    end

    it 'includes context when provided' do
      result = described_class.console_validate_with(model: 'User', attributes: { email: 'a@b.com' },
                                                     context: 'create')
      expect(result[:params][:context]).to eq('create')
    end
  end

  describe '.console_check_eligibility' do
    it 'builds a check_eligibility request' do
      result = described_class.console_check_eligibility(model: 'User', id: 1, feature: 'premium')
      expect(result[:tool]).to eq('check_eligibility')
      expect(result[:params][:model]).to eq('User')
      expect(result[:params][:id]).to eq(1)
      expect(result[:params][:feature]).to eq('premium')
    end
  end

  describe '.console_decorate' do
    it 'builds a decorate request' do
      result = described_class.console_decorate(model: 'User', id: 1)
      expect(result[:tool]).to eq('decorate')
      expect(result[:params][:model]).to eq('User')
      expect(result[:params][:id]).to eq(1)
    end

    it 'includes methods when provided' do
      result = described_class.console_decorate(model: 'User', id: 1, methods: %w[display_name avatar_url])
      expect(result[:params][:methods]).to eq(%w[display_name avatar_url])
    end
  end
end
