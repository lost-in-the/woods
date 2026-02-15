# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/evaluation/baseline_runner'

RSpec.describe CodebaseIndex::Evaluation::BaselineRunner do
  let(:all_identifiers) do
    %w[User UserConcern Post Comment Order OrdersController Product
       SessionsController AuthService UserMailer OrderCreator]
  end

  let(:metadata_store) { instance_double('MetadataStore') }

  let(:runner) { described_class.new(metadata_store: metadata_store) }

  before do
    allow(metadata_store).to receive(:all_identifiers).and_return(all_identifiers)
  end

  describe '#run' do
    it 'raises ArgumentError for invalid strategy' do
      expect { runner.run('test', strategy: :invalid) }
        .to raise_error(ArgumentError, /Invalid strategy/)
    end
  end

  describe 'grep strategy' do
    it 'matches identifiers containing query keywords' do
      results = runner.run('User model', strategy: :grep, limit: 10)

      expect(results).to include('User', 'UserConcern', 'UserMailer')
    end

    it 'is case-insensitive' do
      results = runner.run('user', strategy: :grep, limit: 10)

      expect(results).to include('User', 'UserConcern')
    end

    it 'respects the limit parameter' do
      results = runner.run('User', strategy: :grep, limit: 2)

      expect(results.size).to eq(2)
    end

    it 'filters out stop words' do
      # "the" and "how" are stop words, so only "order" should match
      results = runner.run('How does the order work?', strategy: :grep, limit: 10)

      expect(results).to include('Order', 'OrdersController', 'OrderCreator')
      expect(results).not_to include('User')
    end

    it 'returns empty array when no matches' do
      results = runner.run('nonexistent', strategy: :grep, limit: 10)

      expect(results).to be_empty
    end
  end

  describe 'random strategy' do
    it 'returns random identifiers' do
      results = runner.run('anything', strategy: :random, limit: 3)

      expect(results.size).to eq(3)
      results.each { |r| expect(all_identifiers).to include(r) }
    end

    it 'respects the limit' do
      results = runner.run('anything', strategy: :random, limit: 2)

      expect(results.size).to eq(2)
    end

    it 'does not exceed available identifiers' do
      results = runner.run('anything', strategy: :random, limit: 100)

      expect(results.size).to be <= all_identifiers.size
    end
  end

  describe 'file_level strategy' do
    it 'scores and ranks identifiers by keyword match count' do
      results = runner.run('User controller', strategy: :file_level, limit: 10)

      # "user" matches User, UserConcern, UserMailer
      # "controller" matches OrdersController, SessionsController
      expect(results).to include('User')
    end

    it 'respects the limit' do
      results = runner.run('User', strategy: :file_level, limit: 2)

      expect(results.size).to be <= 2
    end

    it 'returns only matching identifiers' do
      results = runner.run('order', strategy: :file_level, limit: 10)

      results.each do |r|
        expect(r.downcase).to include('order')
      end
    end

    it 'returns empty when no keywords match' do
      results = runner.run('nonexistent', strategy: :file_level, limit: 10)

      expect(results).to be_empty
    end
  end

  describe 'VALID_STRATEGIES' do
    it 'includes grep, random, and file_level' do
      expect(described_class::VALID_STRATEGIES).to contain_exactly(:grep, :random, :file_level)
    end
  end
end
