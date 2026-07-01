# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/embedding/provider'

RSpec.describe Woods::Embedding::Provider do
  describe Woods::Embedding::Provider::Interface do
    let(:dummy_class) do
      Class.new { include Woods::Embedding::Provider::Interface }
    end
    let(:instance) { dummy_class.new }

    it 'raises NotImplementedError for #embed' do
      expect { instance.embed('text') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #embed_batch' do
      expect { instance.embed_batch(%w[a b]) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #dimensions' do
      expect { instance.dimensions }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #model_name' do
      expect { instance.model_name }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #max_input_tokens' do
      expect { instance.max_input_tokens }.to raise_error(NotImplementedError)
    end
  end
end
