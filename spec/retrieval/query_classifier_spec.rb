# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retrieval/query_classifier'

RSpec.describe CodebaseIndex::Retrieval::QueryClassifier do
  subject(:classifier) { described_class.new }

  describe '#classify' do
    it 'returns a Classification struct with all expected fields' do
      result = classifier.classify('How does authentication work?')

      expect(result).to be_a(CodebaseIndex::Retrieval::QueryClassifier::Classification)
      expect(result).to respond_to(:intent, :scope, :target_type, :framework_context, :keywords)
    end
  end

  describe 'intent detection' do
    {
      'Where is the User model defined?' => :locate,
      'Find the payment controller' => :locate,
      'Which file has the Order class?' => :locate,
      'What calls UserService.create?' => :trace,
      'Who calls the authenticate method?' => :trace,
      'Trace the request through middleware' => :trace,
      'What depends on the User model?' => :trace,
      'Fix the bug in checkout' => :debug,
      "There's an error in the payment flow" => :debug,
      'The login is broken' => :debug,
      'Add a new endpoint for orders' => :implement,
      'Create a service for payments' => :implement,
      'Build a new mailer for welcome emails' => :implement,
      'How does has_many work in Rails?' => :framework,
      'What does Rails do with ActiveRecord callbacks?' => :framework,
      'How does ActiveJob process queues?' => :framework,
      'Show me the OrderController interface' => :reference,
      'What is the User model API?' => :reference,
      'List all available scopes' => :reference,
      'Compare User and Admin models' => :compare,
      "What's the difference between Service and Interactor?" => :compare,
      'How does authentication work?' => :understand,
      'Why does the order total include tax?' => :understand,
      'Explain the payment flow' => :understand
    }.each do |query, expected_intent|
      it "classifies #{query.inspect} as #{expected_intent}" do
        result = classifier.classify(query)
        expect(result.intent).to eq(expected_intent)
      end
    end

    it 'defaults to :understand for unrecognized queries' do
      result = classifier.classify('something vague about code')
      expect(result.intent).to eq(:understand)
    end
  end

  describe 'scope detection' do
    {
      'Show me exactly the User model' => :pinpoint,
      'Just the specific migration file' => :pinpoint,
      'Only the checkout controller' => :pinpoint,
      'Show me all models' => :comprehensive,
      'List every controller in the app' => :comprehensive,
      'The entire authentication system' => :comprehensive,
      "What's related to payments?" => :exploratory,
      'Files similar to UserService' => :exploratory,
      'Things associated with the Order model' => :exploratory
    }.each do |query, expected_scope|
      it "classifies #{query.inspect} as #{expected_scope}" do
        result = classifier.classify(query)
        expect(result.scope).to eq(expected_scope)
      end
    end

    it 'defaults to :focused for unrecognized scope' do
      result = classifier.classify('How does authentication work?')
      expect(result.scope).to eq(:focused)
    end
  end

  describe 'target type detection' do
    {
      'user model associations' => :model,
      'the Post schema and columns' => :model,
      'ActiveRecord validation rules' => :model,
      'checkout controller actions' => :controller,
      'API endpoint for orders' => :controller,
      'request filter chain' => :controller,
      'payment service logic' => :service,
      'the CreateOrder interactor' => :service,
      'email job queue' => :job,
      'Sidekiq worker for imports' => :job,
      'background processing' => :job,
      'welcome mailer template' => :mailer,
      'notification email setup' => :mailer,
      'user type graphql fields' => :graphql,
      'the CreateUser mutation' => :graphql,
      'GraphQL resolver for orders' => :graphql
    }.each do |query, expected_type|
      it "classifies #{query.inspect} as #{expected_type}" do
        result = classifier.classify(query)
        expect(result.target_type).to eq(expected_type)
      end
    end

    it 'returns nil when no target type is detected' do
      result = classifier.classify('how does this thing work')
      expect(result.target_type).to be_nil
    end
  end

  describe 'framework context detection' do
    %w[Rails ActiveRecord ActionController ActiveJob ActionMailer ActiveSupport Rack middleware].each do |term|
      it "detects framework context for queries mentioning #{term}" do
        result = classifier.classify("How does #{term} handle this?")
        expect(result.framework_context).to be true
      end
    end

    it 'returns false for non-framework queries' do
      result = classifier.classify('How does the checkout flow work?')
      expect(result.framework_context).to be false
    end
  end

  describe 'keyword extraction' do
    it 'removes stop words' do
      result = classifier.classify('How does the User model handle validation?')
      expect(result.keywords).not_to include('how', 'does', 'the')
    end

    it 'extracts meaningful terms' do
      result = classifier.classify('How does the User model handle validation?')
      expect(result.keywords).to include('user', 'model', 'handle', 'validation')
    end

    it 'removes short words (less than 2 chars)' do
      result = classifier.classify('I want a list of x and y')
      expect(result.keywords).not_to include('i', 'x', 'y')
    end

    it 'deduplicates keywords' do
      result = classifier.classify('model model model')
      expect(result.keywords).to eq(['model'])
    end

    it 'strips punctuation before extracting' do
      result = classifier.classify("What's the User.find method?")
      expect(result.keywords).to include('user', 'method')
    end
  end

  describe 'constants' do
    it 'defines all intent types' do
      expect(described_class::INTENTS).to eq(%i[understand locate trace debug implement reference compare framework])
    end

    it 'defines all scope types' do
      expect(described_class::SCOPES).to eq(%i[pinpoint focused exploratory comprehensive])
    end
  end
end
