# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/chunking/chunk'

RSpec.describe CodebaseIndex::Chunking::Chunk do
  let(:content) { "class User < ApplicationRecord\n  has_many :posts\nend" }

  subject(:chunk) do
    described_class.new(
      content: content,
      chunk_type: :associations,
      parent_identifier: 'User',
      parent_type: :model,
      metadata: { association_count: 1 }
    )
  end

  describe '#initialize' do
    it 'stores all attributes' do
      expect(chunk.content).to eq(content)
      expect(chunk.chunk_type).to eq(:associations)
      expect(chunk.parent_identifier).to eq('User')
      expect(chunk.parent_type).to eq(:model)
      expect(chunk.metadata).to eq({ association_count: 1 })
    end
  end

  describe '#token_count' do
    it 'estimates tokens from content length' do
      expect(chunk.token_count).to eq((content.length / 3.5).ceil)
    end
  end

  describe '#content_hash' do
    it 'computes SHA256 of content' do
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest(content))
    end
  end

  describe '#identifier' do
    it 'combines parent identifier and chunk type' do
      expect(chunk.identifier).to eq('User#associations')
    end
  end

  describe '#to_h' do
    it 'serializes all fields' do
      hash = chunk.to_h
      expect(hash[:content]).to eq(content)
      expect(hash[:chunk_type]).to eq(:associations)
      expect(hash[:parent_identifier]).to eq('User')
      expect(hash[:parent_type]).to eq(:model)
      expect(hash[:token_count]).to be_a(Integer)
      expect(hash[:content_hash]).to be_a(String)
      expect(hash[:identifier]).to eq('User#associations')
      expect(hash[:metadata]).to eq({ association_count: 1 })
    end
  end

  describe '#empty?' do
    it 'returns false when content has text' do
      expect(chunk).not_to be_empty
    end

    it 'returns true when content is blank' do
      blank_chunk = described_class.new(
        content: '  ',
        chunk_type: :summary,
        parent_identifier: 'User',
        parent_type: :model
      )
      expect(blank_chunk).to be_empty
    end
  end
end
