# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/model_validator'

RSpec.describe CodebaseIndex::Console::ModelValidator do
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
        .to raise_error(CodebaseIndex::Console::ValidationError, /Unknown model: Hacker/)
    end

    it 'lists available models in error message' do
      expect { validator.validate_model!('Nope') }
        .to raise_error(CodebaseIndex::Console::ValidationError, /Available: Post, User/)
    end
  end

  describe '#validate_column!' do
    it 'returns true for valid columns' do
      expect(validator.validate_column!('User', 'email')).to be true
    end

    it 'raises ValidationError for unknown columns' do
      expect { validator.validate_column!('User', 'password') }
        .to raise_error(CodebaseIndex::Console::ValidationError, /Unknown column 'password' on User/)
    end

    it 'lists available columns in error message' do
      expect { validator.validate_column!('User', 'foo') }
        .to raise_error(CodebaseIndex::Console::ValidationError, /Available: created_at, email, id, name/)
    end

    it 'raises ValidationError for unknown model first' do
      expect { validator.validate_column!('Bogus', 'id') }
        .to raise_error(CodebaseIndex::Console::ValidationError, /Unknown model: Bogus/)
    end
  end

  describe '#validate_columns!' do
    it 'returns true when all columns are valid' do
      expect(validator.validate_columns!('User', %w[email name])).to be true
    end

    it 'raises on the first invalid column' do
      expect { validator.validate_columns!('User', %w[email bad_col]) }
        .to raise_error(CodebaseIndex::Console::ValidationError, /Unknown column 'bad_col'/)
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
        .to raise_error(CodebaseIndex::Console::ValidationError)
    end
  end
end
