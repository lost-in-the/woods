# frozen_string_literal: true

require 'spec_helper'
require 'woods/notion/mapper'

RSpec.describe Woods::Notion::Mapper do
  describe '.for' do
    it 'returns ModelMapper for model type' do
      expect(described_class.for('model')).to be_a(Woods::Notion::Mappers::ModelMapper)
    end

    it 'returns ColumnMapper for column type' do
      expect(described_class.for('column')).to be_a(Woods::Notion::Mappers::ColumnMapper)
    end

    it 'returns MigrationMapper for migration type' do
      expect(described_class.for('migration')).to be_a(Woods::Notion::Mappers::MigrationMapper)
    end

    it 'returns nil for unsupported types' do
      expect(described_class.for('controller')).to be_nil
      expect(described_class.for('service')).to be_nil
      expect(described_class.for('unknown')).to be_nil
    end
  end

  describe '.supported_types' do
    it 'returns all supported type strings' do
      types = described_class.supported_types
      expect(types).to contain_exactly('model', 'column', 'migration')
    end
  end
end
