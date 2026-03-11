# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/context_assembler'
require 'woods/formatting/base'

RSpec.describe Woods::Formatting::Base do
  subject(:adapter) { described_class.new }

  let(:assembled_context) do
    Woods::Retrieval::AssembledContext.new(
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
end
