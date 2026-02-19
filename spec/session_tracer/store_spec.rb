# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/session_tracer/store'

RSpec.describe CodebaseIndex::SessionTracer::Store do
  subject(:store) { described_class.new }

  describe 'abstract interface' do
    it 'raises NotImplementedError for #record' do
      expect { store.record('sess1', {}) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #read' do
      expect { store.read('sess1') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #sessions' do
      expect { store.sessions }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #clear' do
      expect { store.clear('sess1') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #clear_all' do
      expect { store.clear_all }.to raise_error(NotImplementedError)
    end
  end
end
