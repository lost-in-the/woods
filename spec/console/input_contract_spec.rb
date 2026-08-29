# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/input_contract'

# Direct coverage for the integer normalization contract. Until now it was only
# exercised transitively through DispatchPipeline and EmbeddedExecutor, so a
# hole in the bounds check or the string-key lookup would surface as a Console
# tool misbehaving rather than as a failing spec.
RSpec.describe Woods::Console::InputContract do
  let(:properties) do
    {
      limit: { type: 'integer', minimum: 1, maximum: 100 },
      offset: { type: 'integer', minimum: 0, maximum: 1000 },
      delta: { type: 'integer', minimum: -10, maximum: 10 },
      query: { type: 'string' }
    }
  end

  describe '.normalize!' do
    it 'coerces a well-formed decimal string and returns the same hash' do
      arguments = { limit: '15' }

      result = described_class.normalize!(arguments, properties)

      expect(result).to equal(arguments)
      expect(arguments.fetch(:limit)).to eq(15)
    end

    it 'leaves an already-integer value alone' do
      arguments = { limit: 15 }

      described_class.normalize!(arguments, properties)

      expect(arguments.fetch(:limit)).to eq(15)
    end

    it 'finds values stored under string keys and rewrites them in place' do
      arguments = { 'limit' => '15' }

      described_class.normalize!(arguments, properties)

      expect(arguments).to eq('limit' => 15)
    end

    it 'parses negative integers within bounds' do
      arguments = { delta: '-3' }

      described_class.normalize!(arguments, properties)

      expect(arguments.fetch(:delta)).to eq(-3)
    end

    it 'accepts the declared minimum and maximum boundary values' do
      arguments = { limit: 1, offset: 1000 }

      expect { described_class.normalize!(arguments, properties) }.not_to raise_error
    end

    it 'rejects a value below the minimum' do
      arguments = { limit: 0 }

      expect { described_class.normalize!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be between 1 and 100')
    end

    it 'rejects a value above the maximum' do
      arguments = { limit: 101 }

      expect { described_class.normalize!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be between 1 and 100')
    end

    it 'rejects a non-numeric string' do
      arguments = { limit: 'abc' }

      expect { described_class.normalize!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be an integer')
    end

    it 'rejects a float-formatted string' do
      arguments = { limit: '15.5' }

      expect { described_class.normalize!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be an integer')
    end

    it 'rejects a zero-padded string rather than silently coercing it' do
      arguments = { limit: '015' }

      expect { described_class.normalize!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be an integer')
    end

    it 'rejects a nil value for an integer property' do
      arguments = { limit: nil }

      expect { described_class.normalize!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be an integer')
    end

    it 'leaves string-typed properties untouched' do
      arguments = { query: '15' }

      described_class.normalize!(arguments, properties)

      expect(arguments.fetch(:query)).to eq('15')
    end

    it 'ignores declared properties that are absent from the arguments' do
      arguments = {}

      expect { described_class.normalize!(arguments, properties) }.not_to raise_error
    end
  end

  describe '.reject_string_typed_integers!' do
    # "15" is valid input to parse_integer, so normalize! would coerce it. The
    # JSON-Schema contract disallows any String for an integer property, and
    # callers that skip full schema validation use this check instead.
    it 'rejects a well-formed decimal string for an integer property' do
      arguments = { limit: '15' }

      expect { described_class.reject_string_typed_integers!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be an integer')
    end

    it 'rejects a string value stored under a string key' do
      arguments = { 'limit' => '15' }

      expect { described_class.reject_string_typed_integers!(arguments, properties) }
        .to raise_error(described_class::ValidationError, 'limit must be an integer')
    end

    it 'allows integer values' do
      arguments = { limit: 15 }

      expect { described_class.reject_string_typed_integers!(arguments, properties) }.not_to raise_error
    end

    it 'allows string values for string-typed properties' do
      arguments = { query: 'users' }

      expect { described_class.reject_string_typed_integers!(arguments, properties) }.not_to raise_error
    end

    it 'ignores absent properties' do
      arguments = {}

      expect { described_class.reject_string_typed_integers!(arguments, properties) }.not_to raise_error
    end
  end
end
