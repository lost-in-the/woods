# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/context_assembler'
require 'codebase_index/formatting/claude_adapter'

RSpec.describe CodebaseIndex::Formatting::ClaudeAdapter do
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

    it 'wraps content in <codebase-context> XML' do
      expect(output).to start_with('<codebase-context>')
      expect(output).to end_with('</codebase-context>')
    end

    it 'includes a <meta> tag with tokens and budget' do
      expect(output).to include('<meta tokens="15" budget="8000" />')
    end

    it 'includes a <content> section with indented context' do
      expect(output).to include('<content>')
      expect(output).to include('</content>')
      expect(output).to include('    class User &lt; ApplicationRecord')
    end

    it 'includes a <sources> section with source elements' do
      expect(output).to include('<sources>')
      expect(output).to include('</sources>')
      expect(output).to include('identifier="User"')
      expect(output).to include('type="model"')
      expect(output).to include('score="0.9"')
      expect(output).to include('file="app/models/user.rb"')
    end

    it 'includes all sources' do
      expect(output).to include('identifier="PostsController"')
      expect(output).to include('type="controller"')
      expect(output).to include('score="0.75"')
    end

    it 'escapes XML special characters in content' do
      context_with_xml = CodebaseIndex::Retrieval::AssembledContext.new(
        context: 'if a < b && c > d & "quoted"',
        tokens_used: 10,
        budget: 8000,
        sources: [],
        sections: [:primary]
      )

      result = adapter.format(context_with_xml)
      expect(result).to include('a &lt; b')
      expect(result).to include('c &gt; d')
      expect(result).to include('&amp;')
      expect(result).to include('&quot;quoted&quot;')
    end

    it 'self-closes source elements' do
      expect(output).to include('/>')
      expect(output).not_to include('</source>')
    end
  end

  describe '#format with empty sources' do
    it 'includes an empty sources section' do
      empty = CodebaseIndex::Retrieval::AssembledContext.new(
        context: 'some content',
        tokens_used: 5,
        budget: 8000,
        sources: [],
        sections: [:primary]
      )

      result = adapter.format(empty)
      expect(result).to include('<sources>')
      expect(result).to include('</sources>')
      expect(result).not_to include('<source ')
    end
  end

  describe '#format with empty context' do
    it 'includes an empty content section' do
      empty = CodebaseIndex::Retrieval::AssembledContext.new(
        context: '',
        tokens_used: 0,
        budget: 8000,
        sources: [],
        sections: []
      )

      result = adapter.format(empty)
      expect(result).to include('<content>')
      expect(result).to include('</content>')
    end
  end
end
