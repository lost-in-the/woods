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

    it 'lists available models in error message' do
      expect { validator.validate_model!('Nope') }
        .to raise_error(Woods::Console::ValidationError, /Available: Post, User/)
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

    it 'lists available columns in error message' do
      expect { validator.validate_column!('User', 'foo') }
        .to raise_error(Woods::Console::ValidationError, /Available: created_at, email, id, name/)
    end

    it 'raises ValidationError for unknown model first' do
      expect { validator.validate_column!('Bogus', 'id') }
        .to raise_error(Woods::Console::ValidationError, /Unknown model: Bogus/)
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
