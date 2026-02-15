# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/context_assembler'
require 'codebase_index/formatting/gpt_adapter'

RSpec.describe CodebaseIndex::Formatting::GptAdapter do
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

    it 'starts with a markdown heading' do
      expect(output).to start_with('## Codebase Context')
    end

    it 'includes token usage in bold' do
      expect(output).to include('**Tokens:** 15/8000')
    end

    it 'includes a horizontal rule separator' do
      expect(output).to include('---')
    end

    it 'wraps content in a fenced code block with ruby syntax' do
      expect(output).to include('```ruby')
      expect(output).to include('class User < ApplicationRecord')
      expect(output).to include('```')
    end

    it 'includes sources as a markdown section' do
      expect(output).to include('### Sources')
    end

    it 'formats sources as a bullet list' do
      expect(output).to include('- **User** (model)')
      expect(output).to include('score: 0.9')
      expect(output).to include('file: app/models/user.rb')
      expect(output).to include('- **PostsController** (controller)')
      expect(output).to include('score: 0.75')
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
      expect(result).not_to include('### Sources')
    end
  end

  describe '#format with empty context' do
    it 'includes an empty code block' do
      empty = CodebaseIndex::Retrieval::AssembledContext.new(
        context: '',
        tokens_used: 0,
        budget: 8000,
        sources: [],
        sections: []
      )

      result = adapter.format(empty)
      expect(result).to include('```ruby')
      expect(result).to include('```')
    end
  end
end
