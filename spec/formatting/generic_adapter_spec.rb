# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/context_assembler'
require 'codebase_index/formatting/generic_adapter'

RSpec.describe CodebaseIndex::Formatting::GenericAdapter do
  subject(:adapter) { described_class.new }

  let(:sources) do
    [
      { identifier: 'User', type: :model, score: 0.9, file_path: 'app/models/user.rb' },
      { identifier: 'PostsController', type: :controller, score: 0.75,
        file_path: 'app/controllers/posts_controller.rb' }
    ]
  end

  let(:assembled_context) do
    CodebaseIndex::Retrieval::AssembledContext.new(
      context: "class User < ApplicationRecord\n  has_many :posts\nend",
      tokens_used: 15,
      budget: 8000,
      sources: sources,
      sections: %i[primary supporting]
    )
  end

  describe '#format' do
    let(:output) { adapter.format(assembled_context) }

    it 'starts with a plain text header' do
      expect(output).to include('=== CODEBASE CONTEXT ===')
    end

    it 'includes token usage' do
      expect(output).to include('Tokens: 15 / 8000')
    end

    it 'includes a separator between sections' do
      expect(output).to include('---')
    end

    it 'includes the context content' do
      expect(output).to include('class User < ApplicationRecord')
      expect(output).to include('has_many :posts')
    end

    it 'includes sources in bracket notation' do
      expect(output).to include('[Source: User (model)')
      expect(output).to include('score: 0.9]')
      expect(output).to include('[Source: PostsController (controller)')
      expect(output).to include('score: 0.75]')
    end
  end

  describe '#format with empty sources' do
    it 'omits the sources section' do
      empty = CodebaseIndex::Retrieval::AssembledContext.new(
        context: 'some content',
        tokens_used: 5,
        budget: 8000,
        sources: [],
        sections: [:primary]
      )

      result = adapter.format(empty)
      expect(result).not_to include('[Source:')
    end
  end

  describe '#format with empty context' do
    it 'still includes the header' do
      empty = CodebaseIndex::Retrieval::AssembledContext.new(
        context: '',
        tokens_used: 0,
        budget: 8000,
        sources: [],
        sections: []
      )

      result = adapter.format(empty)
      expect(result).to include('=== CODEBASE CONTEXT ===')
      expect(result).to include('Tokens: 0 / 8000')
    end
  end
end
