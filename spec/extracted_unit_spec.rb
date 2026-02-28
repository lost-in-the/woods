# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CodebaseIndex::ExtractedUnit do
  subject(:unit) do
    described_class.new(
      type: :model,
      identifier: 'User',
      file_path: '/app/models/user.rb'
    )
  end

  describe '#initialize' do
    it 'sets type, identifier, and file_path' do
      expect(unit.type).to eq(:model)
      expect(unit.identifier).to eq('User')
      expect(unit.file_path).to eq('/app/models/user.rb')
    end

    it 'defaults metadata to empty hash' do
      expect(unit.metadata).to eq({})
    end

    it 'defaults dependencies to empty array' do
      expect(unit.dependencies).to eq([])
    end

    it 'defaults dependents to empty array' do
      expect(unit.dependents).to eq([])
    end

    it 'defaults chunks to empty array' do
      expect(unit.chunks).to eq([])
    end
  end

  describe '#to_h' do
    before do
      unit.namespace = 'Admin'
      unit.source_code = 'class User < ApplicationRecord; end'
      unit.metadata = { table_name: 'users' }
      unit.dependencies = [{ type: :service, target: 'UserService' }]
    end

    it 'includes all fields' do
      hash = unit.to_h

      expect(hash[:type]).to eq(:model)
      expect(hash[:identifier]).to eq('User')
      expect(hash[:file_path]).to eq('/app/models/user.rb')
      expect(hash[:namespace]).to eq('Admin')
      expect(hash[:source_code]).to eq('class User < ApplicationRecord; end')
      expect(hash[:metadata]).to eq({ table_name: 'users' })
      expect(hash[:dependencies]).to eq([{ type: :service, target: 'UserService' }])
    end

    it 'includes extracted_at timestamp' do
      expect(unit.to_h[:extracted_at]).to be_a(String)
    end

    it 'includes source_hash' do
      hash = unit.to_h
      expect(hash[:source_hash]).to eq(Digest::SHA256.hexdigest('class User < ApplicationRecord; end'))
    end

    it 'handles nil source_code' do
      unit.source_code = nil
      expect(unit.to_h[:source_hash]).to eq(Digest::SHA256.hexdigest(''))
    end
  end

  describe '#estimated_tokens' do
    it 'estimates tokens at ~4.0 chars per token for Ruby code' do
      unit.source_code = 'a' * 100
      expect(unit.estimated_tokens).to eq(25) # (100 / 4.0).ceil
    end

    it 'returns 0 for nil source_code' do
      unit.source_code = nil
      expect(unit.estimated_tokens).to eq(0)
    end

    it 'rounds up' do
      unit.source_code = 'a' * 5
      expect(unit.estimated_tokens).to eq(2) # (5 / 4.0).ceil
    end

    it 'includes metadata weight when metadata is populated' do
      unit.source_code = 'a' * 100
      unit.metadata = { associations: [{ name: :comments, type: :has_many }], callbacks: [] }
      source_only = (100 / 4.0).ceil
      expect(unit.estimated_tokens).to be > source_only
    end

    it 'does not add metadata tokens when metadata is empty' do
      unit.source_code = 'a' * 100
      unit.metadata = {}
      expect(unit.estimated_tokens).to eq(25) # (100 / 4.0).ceil
    end

    it 'recomputes fresh when source_code changes (no stale memoization)' do
      unit.source_code = 'a' * 100
      first = unit.estimated_tokens

      unit.source_code = 'a' * 500
      second = unit.estimated_tokens

      expect(second).to be > first
      expect(second).to eq((500 / 4.0).ceil)
    end

    it 'invalidates cache when metadata is reassigned via setter' do
      unit.source_code = 'a' * 100
      unit.metadata = {}
      first = unit.estimated_tokens

      unit.metadata = { associations: [{ name: :comments, type: :has_many }] }
      second = unit.estimated_tokens

      expect(second).to be > first
    end

    it 'returns cached value on repeated calls without mutation' do
      unit.source_code = 'a' * 100
      first = unit.estimated_tokens
      second = unit.estimated_tokens

      expect(first).to eq(second)
      expect(first).to equal(second) # same object reference (Fixnum identity)
    end
  end

  describe '#needs_chunking?' do
    it 'returns false for small source' do
      unit.source_code = 'a' * 100
      expect(unit.needs_chunking?).to be false
    end

    it 'returns true for large source' do
      unit.source_code = 'a' * 10_000
      expect(unit.needs_chunking?).to be true
    end

    it 'respects custom threshold' do
      unit.source_code = 'a' * 100
      expect(unit.needs_chunking?(threshold: 10)).to be true
    end
  end

  describe '#build_default_chunks' do
    it 'returns empty for small source' do
      unit.source_code = 'short'
      expect(unit.build_default_chunks).to eq([])
    end

    it 'creates chunks with content_hash' do
      unit.source_code = (["#{'x' * 80}\n"] * 200).join
      chunks = unit.build_default_chunks(max_tokens: 500)

      expect(chunks).not_to be_empty
      chunks.each do |chunk|
        expect(chunk[:content_hash]).to eq(Digest::SHA256.hexdigest(chunk[:content]))
        expect(chunk[:chunk_index]).to be_a(Integer)
        expect(chunk[:identifier]).to start_with('User#chunk_')
        expect(chunk[:estimated_tokens]).to be_a(Integer)
      end
    end

    it 'includes unit header in each chunk' do
      unit.source_code = (["#{'x' * 80}\n"] * 200).join
      chunks = unit.build_default_chunks(max_tokens: 500)

      chunks.each do |chunk|
        expect(chunk[:content]).to include('# Unit: User (model)')
        expect(chunk[:content]).to include('# File: /app/models/user.rb')
      end
    end
  end
end
