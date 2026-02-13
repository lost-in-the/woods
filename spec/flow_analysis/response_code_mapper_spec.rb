# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/flow_analysis/response_code_mapper'

RSpec.describe CodebaseIndex::FlowAnalysis::ResponseCodeMapper do
  describe '.resolve_method' do
    context 'with explicit status kwarg' do
      it 'resolves symbol status from arguments' do
        result = described_class.resolve_method('render', arguments: ['json: user', 'status: :created'])
        expect(result).to eq(201)
      end

      it 'resolves integer status from arguments' do
        result = described_class.resolve_method('render', arguments: ['json: user', 'status: 422'])
        expect(result).to eq(422)
      end

      it 'resolves colon-prefixed symbol from arguments' do
        result = described_class.resolve_method('render', arguments: ['status: :not_found'])
        expect(result).to eq(404)
      end
    end

    context 'with render_<status> convention' do
      it 'resolves render_created to 201' do
        result = described_class.resolve_method('render_created', arguments: [])
        expect(result).to eq(201)
      end

      it 'resolves render_ok to 200' do
        result = described_class.resolve_method('render_ok', arguments: [])
        expect(result).to eq(200)
      end

      it 'resolves render_no_content to 204' do
        result = described_class.resolve_method('render_no_content', arguments: [])
        expect(result).to eq(204)
      end

      it 'resolves render_unprocessable_entity to 422' do
        result = described_class.resolve_method('render_unprocessable_entity', arguments: [])
        expect(result).to eq(422)
      end

      it 'returns nil for unknown render_ suffix' do
        result = described_class.resolve_method('render_foobar', arguments: [])
        expect(result).to be_nil
      end
    end

    context 'with head' do
      it 'resolves head :no_content to 204' do
        result = described_class.resolve_method('head', arguments: [':no_content'])
        expect(result).to eq(204)
      end

      it 'resolves head :ok to 200' do
        result = described_class.resolve_method('head', arguments: [':ok'])
        expect(result).to eq(200)
      end

      it 'returns nil for head with no arguments' do
        result = described_class.resolve_method('head', arguments: [])
        expect(result).to be_nil
      end
    end

    context 'with redirect_to' do
      it 'defaults to 302' do
        result = described_class.resolve_method('redirect_to', arguments: ['root_path'])
        expect(result).to eq(302)
      end

      it 'uses explicit status kwarg over default' do
        result = described_class.resolve_method('redirect_to', arguments: ['root_path', 'status: :moved_permanently'])
        expect(result).to eq(301)
      end
    end

    context 'with plain render (no status)' do
      it 'returns nil when no status is determinable' do
        result = described_class.resolve_method('render', arguments: ['json: user'])
        expect(result).to be_nil
      end
    end

    context 'with unrecognized method' do
      it 'returns nil' do
        result = described_class.resolve_method('some_method', arguments: [])
        expect(result).to be_nil
      end
    end
  end

  describe '.resolve_status' do
    it 'resolves symbol to status code' do
      expect(described_class.resolve_status(:ok)).to eq(200)
      expect(described_class.resolve_status(:created)).to eq(201)
      expect(described_class.resolve_status(:not_found)).to eq(404)
    end

    it 'passes through integers' do
      expect(described_class.resolve_status(200)).to eq(200)
      expect(described_class.resolve_status(404)).to eq(404)
    end

    it 'resolves colon-prefixed strings' do
      expect(described_class.resolve_status(':created')).to eq(201)
      expect(described_class.resolve_status(':no_content')).to eq(204)
    end

    it 'resolves plain string symbol names' do
      expect(described_class.resolve_status('created')).to eq(201)
    end

    it 'resolves integer strings' do
      expect(described_class.resolve_status('201')).to eq(201)
    end

    it 'returns nil for unknown symbol names' do
      expect(described_class.resolve_status(':foobar')).to be_nil
    end

    it 'returns nil for nil input' do
      expect(described_class.resolve_status(nil)).to be_nil
    end
  end
end
