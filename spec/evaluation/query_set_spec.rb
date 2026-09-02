# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/evaluation/query_set'

RSpec.describe Woods::Evaluation::QuerySet do
  let(:sample_queries) do
    [
      described_class::Query.new(
        query: 'How does the User model work?',
        expected_units: %w[User UserConcern],
        intent: :locate,
        scope: :pinpoint,
        tags: %w[model auth]
      ),
      described_class::Query.new(
        query: 'Trace the order creation flow',
        expected_units: %w[Order OrdersController OrderCreator],
        intent: :trace,
        scope: :focused,
        tags: %w[flow orders]
      ),
      described_class::Query.new(
        query: 'Compare payment processing strategies',
        expected_units: %w[StripeProcessor PaypalProcessor],
        intent: :compare,
        scope: :exploratory,
        tags: %w[payments]
      )
    ]
  end

  let(:query_set) { described_class.new(queries: sample_queries) }

  describe '#initialize' do
    it 'creates a query set with queries' do
      expect(query_set.queries).to eq(sample_queries)
    end

    it 'defaults to an empty array' do
      empty_set = described_class.new
      expect(empty_set.queries).to eq([])
    end
  end

  describe '#size' do
    it 'returns the number of queries' do
      expect(query_set.size).to eq(3)
    end

    it 'returns 0 for empty set' do
      expect(described_class.new.size).to eq(0)
    end
  end

  describe '#add' do
    it 'rejects required_units that are not a subset of expected_units' do
      query = described_class::Query.new(
        query: 'q', expected_units: %w[User], required_units: %w[Ghost],
        intent: :locate, scope: :pinpoint, tags: []
      )

      expect { query_set.add(query) }.to raise_error(ArgumentError, /subset of expected_units/)
    end

    it 'accepts required_units that are a subset of expected_units' do
      query = described_class::Query.new(
        query: 'q', expected_units: %w[User Post], required_units: %w[User],
        intent: :locate, scope: :pinpoint, tags: []
      )

      expect { query_set.add(query) }.not_to raise_error
    end

    it 'adds a valid query' do
      new_query = described_class::Query.new(
        query: 'Explain the mailer system',
        expected_units: ['UserMailer'],
        intent: :understand,
        scope: :focused,
        tags: %w[mailer]
      )

      query_set.add(new_query)

      expect(query_set.size).to eq(4)
      expect(query_set.queries.last).to eq(new_query)
    end

    it 'raises ArgumentError for invalid intent' do
      bad_query = described_class::Query.new(
        query: 'test',
        expected_units: [],
        intent: :invalid,
        scope: :pinpoint,
        tags: []
      )

      expect { query_set.add(bad_query) }.to raise_error(ArgumentError, /Invalid intent/)
    end

    it 'raises ArgumentError for invalid scope' do
      bad_query = described_class::Query.new(
        query: 'test',
        expected_units: [],
        intent: :locate,
        scope: :invalid,
        tags: []
      )

      expect { query_set.add(bad_query) }.to raise_error(ArgumentError, /Invalid scope/)
    end
  end

  describe '#filter' do
    it 'filters by intent' do
      result = query_set.filter(intent: :locate)

      expect(result.size).to eq(1)
      expect(result.first.query).to eq('How does the User model work?')
    end

    it 'filters by scope' do
      result = query_set.filter(scope: :focused)

      expect(result.size).to eq(1)
      expect(result.first.query).to eq('Trace the order creation flow')
    end

    it 'filters by tags' do
      result = query_set.filter(tags: %w[payments])

      expect(result.size).to eq(1)
      expect(result.first.query).to eq('Compare payment processing strategies')
    end

    it 'combines multiple filters' do
      result = query_set.filter(intent: :locate, scope: :pinpoint)

      expect(result.size).to eq(1)
    end

    it 'returns all queries when no filters specified' do
      result = query_set.filter

      expect(result.size).to eq(3)
    end

    it 'returns empty array when no matches' do
      result = query_set.filter(intent: :understand)

      expect(result).to be_empty
    end
  end

  describe '.load and #save' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:json_path) { File.join(tmpdir, 'test_queries.json') }

    after { FileUtils.remove_entry(tmpdir) }

    let(:json_data) do
      {
        'queries' => [
          {
            'query' => 'How does User model work?',
            'expected_units' => %w[User],
            'intent' => 'lookup',
            'scope' => 'specific',
            'tags' => %w[model]
          },
          {
            'query' => 'Trace the login flow',
            'expected_units' => %w[SessionsController AuthService],
            'intent' => 'trace',
            'scope' => 'bounded',
            'tags' => %w[auth]
          }
        ]
      }
    end

    it 'loads queries from a JSON file' do
      File.write(json_path, JSON.generate(json_data))

      loaded = described_class.load(json_path)

      expect(loaded.size).to eq(2)
      expect(loaded.queries.first.query).to eq('How does User model work?')
      expect(loaded.queries.first.intent).to eq(:locate)
      expect(loaded.queries.first.expected_units).to eq(%w[User])
    end

    it 'saves and reloads a query set' do
      query_set.save(json_path)

      loaded = described_class.load(json_path)

      expect(loaded.size).to eq(query_set.size)
      expect(loaded.queries.map(&:query)).to eq(query_set.queries.map(&:query))
    end

    # EXP-10. `context_completeness` was scored against `expected_units`,
    # making it recall under a second name. The optional `required_units`
    # annotation is the subset a retrieval must surface.
    it 'loads an optional required_units annotation' do
      File.write(json_path, JSON.generate(
                              'queries' => [
                                { 'query' => 'Trace the login flow',
                                  'expected_units' => %w[SessionsController AuthService],
                                  'required_units' => %w[SessionsController] }
                              ]
                            ))

      loaded = described_class.load(json_path)

      expect(loaded.queries.first.required_units).to eq(%w[SessionsController])
      expect(loaded.queries.first.completeness_units).to eq(%w[SessionsController])
    end

    it 'defaults completeness_units to the expected set when unannotated' do
      loaded = described_class.load(json_path.tap { |path| File.write(path, JSON.generate(json_data)) })

      expect(loaded.queries.first.required_units).to be_nil
      expect(loaded.queries.first.completeness_units).to eq(%w[User])
    end

    it 'round-trips required_units through save' do
      set = described_class.new(queries: [
                                  described_class::Query.new(
                                    query: 'Trace the login flow',
                                    expected_units: %w[SessionsController AuthService],
                                    required_units: %w[AuthService],
                                    intent: :trace, scope: :focused, tags: []
                                  )
                                ])
      set.save(json_path)

      expect(described_class.load(json_path).queries.first.required_units).to eq(%w[AuthService])
    end

    it 'omits required_units from the JSON when unannotated' do
      query_set.save(json_path)

      JSON.parse(File.read(json_path))['queries'].each do |raw|
        expect(raw).not_to have_key('required_units')
      end
    end

    it 'raises Woods::Error for missing file' do
      expect { described_class.load('/nonexistent/file.json') }
        .to raise_error(Woods::Error, /file not found/i)
    end

    it 'raises Woods::Error for invalid JSON' do
      File.write(json_path, 'not valid json{{{')

      expect { described_class.load(json_path) }
        .to raise_error(Woods::Error, /Invalid JSON/i)
    end

    it 'handles missing optional fields with defaults' do
      minimal_data = {
        'queries' => [
          { 'query' => 'simple query' }
        ]
      }
      File.write(json_path, JSON.generate(minimal_data))

      loaded = described_class.load(json_path)

      expect(loaded.queries.first.expected_units).to eq([])
      # Defaults match the classifier's own defaults, so an unannotated query
      # is annotated with what the pipeline would infer for it anyway.
      expect(loaded.queries.first.intent).to eq(:understand)
      expect(loaded.queries.first.scope).to eq(:focused)
      expect(loaded.queries.first.tags).to eq([])
    end
  end

  describe 'Query struct' do
    it 'supports keyword initialization' do
      q = described_class::Query.new(
        query: 'test',
        expected_units: %w[A B],
        intent: :locate,
        scope: :pinpoint,
        tags: %w[foo]
      )

      expect(q.query).to eq('test')
      expect(q.expected_units).to eq(%w[A B])
      expect(q.intent).to eq(:locate)
      expect(q.scope).to eq(:pinpoint)
      expect(q.tags).to eq(%w[foo])
    end
  end

  describe 'VALID_INTENTS' do
    it 'matches the QueryClassifier intent vocabulary' do
      # The point is that these ARE the classifier's lists, not a parallel
      # invention that ground truth could never be compared against (#218).
      expect(described_class::VALID_INTENTS).to eq(Woods::Retrieval::QueryClassifier::INTENTS)
    end
  end

  describe 'VALID_SCOPES' do
    it 'matches the QueryClassifier scope vocabulary' do
      expect(described_class::VALID_SCOPES).to eq(Woods::Retrieval::QueryClassifier::SCOPES)
    end
  end
end
