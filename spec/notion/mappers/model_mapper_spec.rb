# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/notion/mappers/model_mapper'

RSpec.describe CodebaseIndex::Notion::Mappers::ModelMapper do
  subject(:mapper) { described_class.new }

  let(:full_unit_data) do
    {
      'type' => 'model',
      'identifier' => 'User',
      'file_path' => 'app/models/user.rb',
      'namespace' => nil,
      'source_code' => "# Represents a registered user account.\nclass User < ApplicationRecord\nend",
      'metadata' => {
        'table_name' => 'users',
        'associations' => [
          { 'name' => 'posts', 'type' => 'has_many', 'target' => 'Post' },
          { 'name' => 'profile', 'type' => 'has_one', 'target' => 'Profile' },
          { 'name' => 'organization', 'type' => 'belongs_to', 'target' => 'Organization', 'foreign_key' => 'org_id' }
        ],
        'validations' => [
          { 'attribute' => 'email', 'type' => 'presence' },
          { 'attribute' => 'email', 'type' => 'uniqueness', 'options' => { 'scope' => 'org_id' } },
          { 'attribute' => 'name', 'type' => 'presence' }
        ],
        'callbacks' => [
          { 'type' => 'after_create', 'filter' => 'send_welcome_email', 'kind' => 'after',
            'side_effects' => { 'jobs_enqueued' => ['WelcomeEmailJob'] } },
          { 'type' => 'before_save', 'filter' => 'normalize_email', 'kind' => 'before' }
        ],
        'scopes' => [
          { 'name' => 'active', 'type' => 'scope' },
          { 'name' => 'recent', 'type' => 'scope' }
        ],
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false },
          { 'name' => 'email', 'type' => 'string', 'null' => false, 'limit' => 255 },
          { 'name' => 'name', 'type' => 'string', 'null' => true },
          { 'name' => 'created_at', 'type' => 'datetime', 'null' => false }
        ],
        'column_count' => 4,
        'git' => {
          'last_modified' => '2026-02-20T10:30:00Z',
          'change_frequency' => 'active',
          'commit_count' => 47
        }
      },
      'dependencies' => [
        { 'type' => 'job', 'target' => 'WelcomeEmailJob', 'via' => 'perform_later' },
        { 'type' => 'service', 'target' => 'UserService', 'via' => 'instantiation' }
      ]
    }
  end

  let(:minimal_unit_data) do
    {
      'type' => 'model',
      'identifier' => 'Setting',
      'file_path' => 'app/models/setting.rb',
      'source_code' => "class Setting < ApplicationRecord\nend",
      'metadata' => {},
      'dependencies' => []
    }
  end

  let(:namespaced_unit_data) do
    {
      'type' => 'model',
      'identifier' => 'Admin::AuditLog',
      'file_path' => 'app/models/admin/audit_log.rb',
      'namespace' => 'Admin',
      'source_code' => "class Admin::AuditLog < ApplicationRecord\nend",
      'metadata' => {
        'table_name' => 'admin_audit_logs',
        'columns' => [
          { 'name' => 'id', 'type' => 'bigint', 'null' => false }
        ],
        'column_count' => 1
      },
      'dependencies' => []
    }
  end

  describe '#map' do
    context 'with a full model unit' do
      let(:result) { mapper.map(full_unit_data) }

      it 'sets Table Name as title property' do
        title = result['Table Name']
        expect(title).to eq({ title: [{ text: { content: 'users' } }] })
      end

      it 'sets Model Name as rich_text' do
        model_name = result['Model Name']
        expect(model_name[:rich_text].first[:text][:content]).to eq('User')
      end

      it 'extracts description from source code comments' do
        desc = result['Description']
        expect(desc[:rich_text].first[:text][:content]).to include('Represents a registered user account')
      end

      it 'formats associations' do
        assoc = result['Associations'][:rich_text].first[:text][:content]
        expect(assoc).to include('has_many :posts')
        expect(assoc).to include('has_one :profile')
        expect(assoc).to include('belongs_to :organization')
      end

      it 'formats validations' do
        validations = result['Validations'][:rich_text].first[:text][:content]
        expect(validations).to include('email')
        expect(validations).to include('presence')
        expect(validations).to include('uniqueness')
      end

      it 'formats callbacks with side effects' do
        callbacks = result['Callbacks'][:rich_text].first[:text][:content]
        expect(callbacks).to include('after_create')
        expect(callbacks).to include('send_welcome_email')
      end

      it 'formats scopes' do
        scopes = result['Scopes'][:rich_text].first[:text][:content]
        expect(scopes).to include('active')
        expect(scopes).to include('recent')
      end

      it 'sets Column Count as number' do
        expect(result['Column Count']).to eq({ number: 4 })
      end

      it 'sets Last Modified as date from git metadata' do
        expect(result['Last Modified']).to eq({ date: { start: '2026-02-20T10:30:00Z' } })
      end

      it 'sets Change Frequency as select' do
        expect(result['Change Frequency']).to eq({ select: { name: 'active' } })
      end

      it 'sets File Path' do
        path = result['File Path'][:rich_text].first[:text][:content]
        expect(path).to eq('app/models/user.rb')
      end

      it 'formats dependencies' do
        deps = result['Dependencies'][:rich_text].first[:text][:content]
        expect(deps).to include('WelcomeEmailJob')
        expect(deps).to include('UserService')
      end
    end

    context 'with a minimal model unit' do
      let(:result) { mapper.map(minimal_unit_data) }

      it 'derives table name from identifier when missing' do
        title = result['Table Name']
        expect(title).to eq({ title: [{ text: { content: 'settings' } }] })
      end

      it 'handles empty associations' do
        assoc = result['Associations'][:rich_text].first[:text][:content]
        expect(assoc).to eq('None')
      end

      it 'handles empty validations' do
        validations = result['Validations'][:rich_text].first[:text][:content]
        expect(validations).to eq('None')
      end

      it 'handles empty callbacks' do
        callbacks = result['Callbacks'][:rich_text].first[:text][:content]
        expect(callbacks).to eq('None')
      end

      it 'handles missing git metadata' do
        expect(result['Last Modified']).to be_nil
        expect(result['Change Frequency']).to be_nil
      end

      it 'defaults Column Count to 0' do
        expect(result['Column Count']).to eq({ number: 0 })
      end
    end

    context 'with a namespaced model' do
      let(:result) { mapper.map(namespaced_unit_data) }

      it 'uses explicit table_name' do
        title = result['Table Name']
        expect(title).to eq({ title: [{ text: { content: 'admin_audit_logs' } }] })
      end

      it 'sets full identifier as Model Name' do
        model_name = result['Model Name'][:rich_text].first[:text][:content]
        expect(model_name).to eq('Admin::AuditLog')
      end
    end
  end
end
