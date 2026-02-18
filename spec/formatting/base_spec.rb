# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/context_assembler'
require 'codebase_index/formatting/base'

RSpec.describe CodebaseIndex::Formatting::Base do
  subject(:adapter) { described_class.new }

  let(:assembled_context) do
    CodebaseIndex::Retrieval::AssembledContext.new(
      context: 'class User < ApplicationRecord; end',
      tokens_used: 10,
      budget: 8000,
      sources: [
        { identifier: 'User', type: :model, score: 0.9, file_path: 'app/models/user.rb' }
      ],
      sections: [:primary]
    )
  end

  describe '#format' do
    it 'raises NotImplementedError' do
      expect { adapter.format(assembled_context) }.to raise_error(NotImplementedError)
    end
  end

  describe '#estimate_tokens' do
    it 'estimates tokens using the project convention (length / 4.0 ceil)' do
      # estimate_tokens is private, so we test through a subclass
      subclass = Class.new(described_class) do
        def format(assembled_context)
          estimate_tokens(assembled_context.context)
        end
      end

      result = subclass.new.format(assembled_context)
      expected = (assembled_context.context.length / 4.0).ceil
      expect(result).to eq(expected)
    end

    it 'returns 0 for empty string' do
      subclass = Class.new(described_class) do
        def format(_assembled_context)
          estimate_tokens('')
        end
      end

      result = subclass.new.format(assembled_context)
      expect(result).to eq(0)
    end
  end
end
