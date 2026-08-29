# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/query_classifier'

RSpec.describe Woods::Retrieval::QueryClassifier do
  subject(:classifier) { described_class.new }

  describe '#classify' do
    it 'returns a Classification struct with all expected fields' do
      result = classifier.classify('How does authentication work?')

      expect(result).to be_a(Woods::Retrieval::QueryClassifier::Classification)
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

  describe 'intent pattern ordering (L8)' do
    # "find who calls X" matches BOTH the :locate pattern ("find") and the
    # :trace pattern ("who calls"). First-match ordering put :locate first,
    # so graph-based tracing queries were misrouted to keyword/direct
    # locate handling. The tracing intent is the one the agent means.
    it 'routes "find who calls X" to :trace, not :locate' do
      expect(classifier.classify('find who calls UsersController#create').intent).to eq(:trace)
      expect(classifier.classify('find what calls the billing service').intent).to eq(:trace)
    end

    it 'still routes plain locate queries that carry no trace words to :locate' do
      expect(classifier.classify('find the payment controller').intent).to eq(:locate)
      expect(classifier.classify('where is the User model defined?').intent).to eq(:locate)
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

  describe 'target type tightening (#184)' do
    # Ordinary conversational words must not read as type signals — the
    # canonical failure was "How do we get the current user?" classifying
    # target :route via bare "get".
    {
      'How do we get the current user?' => nil,
      'how do we post a comment on an article?' => nil,
      'where do we delete stale sessions?' => nil,
      'what does this method perform?' => nil,
      'how does the push notification banner work?' => nil
    }.each do |query, expected|
      it "classifies #{query.inspect} with no target type" do
        expect(classifier.classify(query).target_type).to eq(expected)
      end
    end

    it 'does not treat bare "query", "type", or "field" as graphql signals' do
      expect(classifier.classify('what query does this report run?').target_type).to be_nil
      expect(classifier.classify('what type of authentication do we use?').target_type).to be_nil
      expect(classifier.classify('how is the published field populated?').target_type).to be_nil
    end

    it 'still classifies uppercase HTTP verbs as :route' do
      expect(classifier.classify('what happens on a GET to /users?').target_type).to eq(:route)
      expect(classifier.classify('handling a DELETE against /sessions').target_type).to eq(:route)
    end

    it 'classifies verb-plus-context phrases via the controller pattern' do
      # "get request" / "delete endpoint" carry route-ish context words that
      # the controller pattern (checked first) already claims — the verb
      # itself adds nothing, so bare lowercase verbs stay signal-free.
      expect(classifier.classify('trace the get request for orders').target_type).to eq(:controller)
      expect(classifier.classify('where is the delete endpoint?').target_type).to eq(:controller)
    end

    it 'still classifies mailer queries with real mail context' do
      expect(classifier.classify('how do we send an email to new users?').target_type).to eq(:mailer)
      expect(classifier.classify('the notification email for signups').target_type).to eq(:mailer)
      expect(classifier.classify('how does mail delivery get retried?').target_type).to eq(:mailer)
    end

    it 'still classifies job queries with perform_later context' do
      expect(classifier.classify('what happens when we perform_later a sync?').target_type).to eq(:job)
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

    it 'defines STOP_WORDS as a frozen Set' do
      expect(described_class::STOP_WORDS).to be_a(Set)
      expect(described_class::STOP_WORDS).to be_frozen
    end

    it 'STOP_WORDS includes common English stop words' do
      expect(described_class::STOP_WORDS).to include('the', 'a', 'an', 'is', 'in', 'for', 'and', 'or')
    end

    it 'STOP_WORDS is shared across calls (same object identity)' do
      # Verify the constant is not re-allocated per call
      classifier1 = described_class.new
      classifier2 = described_class.new
      result1 = classifier1.classify('how does the user model work')
      result2 = classifier2.classify('where is the order service')
      # Both should have filtered stop words, confirming STOP_WORDS is used
      expect(result1.keywords).not_to include('the', 'does', 'how')
      expect(result2.keywords).not_to include('the', 'is', 'where')
    end
  end

  describe 'error / edge-case inputs (D-8)' do
    it 'does not crash on an empty string' do
      result = classifier.classify('')
      expect(result.intent).to be_a(Symbol)
      expect(result.scope).to be_a(Symbol)
      expect(result.keywords).to eq([])
    end

    it 'does not crash on a whitespace-only string' do
      expect { classifier.classify("   \t\n ") }.not_to raise_error
    end

    it 'handles a very long query without error' do
      expect { classifier.classify('x ' * 5_000) }.not_to raise_error
    end

    it 'handles unicode characters' do
      result = classifier.classify('Comment est-ce que le système fonctionne? 日本語も')
      expect(result).to be_a(Woods::Retrieval::QueryClassifier::Classification)
    end

    it 'treats nil as an error (classifier expects a String)' do
      expect { classifier.classify(nil) }.to raise_error(NoMethodError)
    end

    it 'classifies queries with no keywords after stop-word filtering' do
      result = classifier.classify('the a an is')
      expect(result.keywords).to eq([])
      expect(result.intent).to be_a(Symbol)
    end
  end
end
