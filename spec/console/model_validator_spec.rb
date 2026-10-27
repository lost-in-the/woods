# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/model_validator'

RSpec.describe Woods::Console::ModelValidator do
  let(:registry) do
    {
      'User' => %w[id email name created_at],
      'Post' => %w[id title body user_id published_at]
    }
  end

  subject(:validator) { described_class.new(registry: registry) }

  describe '#validate_model!' do
    it 'returns true for known models' do
      expect(validator.validate_model!('User')).to be true
      expect(validator.validate_model!('Post')).to be true
    end

    it 'raises ValidationError for unknown models' do
      expect { validator.validate_model!('Hacker') }
        .to raise_error(Woods::Console::ValidationError, /Unknown model: Hacker/)
    end

    it 'reports the known count instead of listing models when nothing is close' do
      expect { validator.validate_model!('Nope') }
        .to raise_error(Woods::Console::ValidationError,
                        'Unknown model: Nope. No close match among 2 known models.')
    end

    it 'suggests near matches with the known count' do
      expect { validator.validate_model!('Usr') }
        .to raise_error(Woods::Console::ValidationError,
                        'Unknown model: Usr. Did you mean: User? (2 known models)')
    end
  end

  describe '#validate_column!' do
    it 'returns true for valid columns' do
      expect(validator.validate_column!('User', 'email')).to be true
    end

    it 'raises ValidationError for unknown columns' do
      expect { validator.validate_column!('User', 'password') }
        .to raise_error(Woods::Console::ValidationError, /Unknown column 'password' on User/)
    end

    it 'reports the known count instead of listing columns when nothing is close' do
      expect { validator.validate_column!('User', 'foo') }
        .to raise_error(Woods::Console::ValidationError,
                        "Unknown column 'foo' on User. No close match among 4 known columns.")
    end

    it 'suggests near matches with the known count' do
      expect { validator.validate_column!('User', 'emial') }
        .to raise_error(Woods::Console::ValidationError,
                        "Unknown column 'emial' on User. Did you mean: email? (4 known columns)")
    end

    it 'raises ValidationError for unknown model first' do
      expect { validator.validate_column!('Bogus', 'id') }
        .to raise_error(Woods::Console::ValidationError, /Unknown model: Bogus/)
    end
  end

  describe 'bounded suggestions' do
    let(:large_registry) do
      (1..500).to_h { |i| ["Model#{format('%03d', i)}", %w[id]] }.merge(
        'Account' => (1..200).map { |i| "col_#{format('%03d', i)}" } + %w[id]
      )
    end

    subject(:large) { described_class.new(registry: large_registry) }

    def message_for
      yield
    rescue Woods::Console::ValidationError => e
      e.message
    end

    it 'caps model suggestions and reports the total' do
      message = message_for { large.validate_model!('Model00') }

      expect(message.scan(/Model\d{3}/).size).to eq(described_class::MAX_SUGGESTIONS)
      expect(message).to include('(501 known models)')
    end

    it 'caps column suggestions and reports the total' do
      message = message_for { large.validate_column!('Account', 'col_00') }

      expect(message.scan(/col_\d{3}/).size).to eq(described_class::MAX_SUGGESTIONS)
      expect(message).to include('(201 known columns)')
    end

    it 'is deterministic regardless of registry insertion order' do
      shuffled = described_class.new(registry: large_registry.to_a.reverse.to_h)

      expect(message_for { shuffled.validate_model!('Model00') })
        .to eq(message_for { large.validate_model!('Model00') })
    end

    it 'keeps the message short for an unrelated name' do
      message = message_for { large.validate_model!('Zzzzzzzz') }

      expect(message).to eq('Unknown model: Zzzzzzzz. No close match among 501 known models.')
    end

    it 'ranks the closest match first' do
      expect { large.validate_model!('Acount') }
        .to raise_error(Woods::Console::ValidationError, /Did you mean: Account/)
    end
  end

  describe 'suggestions and hidden names' do
    subject(:validator) do
      described_class.new(
        registry: { 'Identity' => %w[id email password_digest], 'Post' => %w[id title body] },
        table_names: { 'Identity' => 'identities', 'Post' => 'posts' },
        hidden_tables: %w[Identities],
        hidden_columns: %w[Password_Digest]
      )
    end

    it 'never suggests a model on a blocked table' do
      expect { validator.validate_model!('Identit') }
        .to raise_error(Woods::Console::ValidationError, 'Unknown model: Identit. No close match among 1 known model.')
    end

    it 'never suggests or counts a redacted column' do
      expect { validator.validate_column!('Identity', 'password_digets') }
        .to raise_error(Woods::Console::ValidationError,
                        "Unknown column 'password_digets' on Identity. No close match among 2 known columns.")
    end

    it 'still accepts a real name that is hidden from suggestions' do
      expect(validator.validate_column!('Identity', 'password_digest')).to be true
    end
  end

  describe '#validate_columns!' do
    it 'passes when all columns are valid' do
      expect { validator.validate_columns!('User', %w[email name]) }.not_to raise_error
    end

    it 'raises on the first invalid column' do
      expect { validator.validate_columns!('User', %w[email bad_col]) }
        .to raise_error(Woods::Console::ValidationError, /Unknown column 'bad_col'/)
    end
  end

  describe '#validate_table_column!' do
    subject(:validator) do
      described_class.new(registry: registry, table_names: { 'User' => 'users', 'Post' => 'posts' })
    end

    it 'returns true for a column that exists on the mapped table' do
      expect(validator.validate_table_column!('users', 'email')).to be true
    end

    it 'raises ValidationError for a column that does not exist on the mapped table' do
      expect { validator.validate_table_column!('users', 'password_digest') }
        .to raise_error(Woods::Console::ValidationError, /Unknown column 'password_digest' on User/)
    end

    it 'raises ValidationError for a table with no known model mapping' do
      expect { validator.validate_table_column!('secrets', 'value') }
        .to raise_error(Woods::Console::ValidationError, /Unknown table 'secrets'/)
    end

    it 'fails closed when the validator was built without table_names' do
      bare_validator = described_class.new(registry: registry)

      expect { bare_validator.validate_table_column!('users', 'email') }
        .to raise_error(Woods::Console::ValidationError, /Unknown table 'users'/)
    end
  end

  describe '#model_names' do
    it 'returns sorted model names' do
      expect(validator.model_names).to eq(%w[Post User])
    end
  end

  describe '#columns_for' do
    it 'returns sorted columns for a known model' do
      expect(validator.columns_for('User')).to eq(%w[created_at email id name])
    end

    it 'raises for unknown models' do
      expect { validator.columns_for('Nope') }
        .to raise_error(Woods::Console::ValidationError)
    end
  end
end
