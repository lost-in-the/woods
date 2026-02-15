# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/context_assembler'
require 'codebase_index/formatting/human_adapter'

RSpec.describe CodebaseIndex::Formatting::HumanAdapter do
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

    it 'includes box-drawing header characters' do
      lines = output.lines
      expect(lines[0]).to include("\u2554") # top-left corner
      expect(lines[0]).to include("\u2557") # top-right corner
      expect(lines[2]).to include("\u255A") # bottom-left corner
      expect(lines[2]).to include("\u255D") # bottom-right corner
    end

    it 'includes the title in the box' do
      expect(output).to include("\u2551 Codebase Context")
    end

    it 'includes token usage' do
      expect(output).to include('Tokens: 15 / 8000')
    end

    it 'includes the context content' do
      expect(output).to include('class User < ApplicationRecord')
      expect(output).to include('has_many :posts')
    end

    it 'includes source entries with box-drawing decorators' do
      expect(output).to include("\u2500\u2500 User (model)")
      expect(output).to include('score: 0.9')
      expect(output).to include("\u2500\u2500 PostsController (controller)")
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
      expect(result).not_to include('Sources')
    end
  end

  describe '#format with empty context' do
    it 'still includes the header box' do
      empty = CodebaseIndex::Retrieval::AssembledContext.new(
        context: '',
        tokens_used: 0,
        budget: 8000,
        sources: [],
        sections: []
      )

      result = adapter.format(empty)
      expect(result).to include("\u2554")
      expect(result).to include('Tokens: 0 / 8000')
    end
  end
end
