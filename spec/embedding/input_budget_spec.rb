# frozen_string_literal: true

require 'spec_helper'
require 'woods/embedding/openai'
require 'woods/embedding/input_budget'

RSpec.describe Woods::Embedding::InputBudget do
  %w[text-embedding-3-small text-embedding-3-large text-embedding-ada-002].each do |model|
    it "uses the conservative byte-BPE bound for #{model} without a tokenizer dependency" do
      provider = Woods::Embedding::Provider::OpenAI.new(api_key: 'offline', model: model)
      budget = provider.input_budget
      expect(budget.method).to eq('utf8_bytes_bound')
      # Exact cl100k counts from the official tokenizer cookbook. The bound
      # deliberately overcounts these samples; it never uses chars/4 admission.
      { 'antidisestablishmentarianism' => 6, '2 + 2 = 4' => 7, 'お誕生日おめでとう' => 9 }.each do |text, exact|
        expect(budget.count(text)).to eq(text.bytesize)
        expect(budget.count(text)).to be >= exact
      end
      expect(budget.limit).to eq(8191)
    end
  end

  it 'does not claim an exact count or byte-BPE bound for unknown OpenAI or Ollama models' do
    providers = [Woods::Embedding::Provider::OpenAI.new(api_key: 'offline', model: 'custom'),
                 Woods::Embedding::Provider::Ollama.new(model: 'custom')]
    providers.each do |provider|
      expect(provider.input_budget.method).to eq('estimate')
      expect(provider.input_budget.model).to eq('custom')
    end
  end

  it 'rejects invalid UTF-8 without repairing or truncating the input' do
    invalid = "\xFF".dup.force_encoding(Encoding::UTF_8)
    budget = described_class.new(limit: 10, method: 'utf8_bytes_bound')
    expect { budget.validate!(invalid) }.to raise_error(Woods::Embedding::InputLimitError, /valid UTF-8/)
    expect(invalid.bytes).to eq([255])
  end

  it 'accepts valid ASCII regardless of its Ruby encoding label' do
    budget = described_class.new(limit: 10, method: 'utf8_bytes_bound')
    expect(budget.count('ascii'.b)).to eq(5)
  end

  it 'refuses a nonpositive limit rather than creating empty slices' do
    expect { described_class.new(limit: 0) }.to raise_error(ArgumentError, /positive/)
  end
end
