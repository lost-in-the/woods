# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/embedding/text_preparer'

RSpec.describe CodebaseIndex::Embedding::TextPreparer do
  subject(:preparer) { described_class.new }

  let(:unit) do
    CodebaseIndex::ExtractedUnit.new(
      type: :model,
      identifier: 'User',
      file_path: 'app/models/user.rb'
    ).tap do |u|
      u.namespace = 'Admin'
      u.source_code = "class User < ApplicationRecord\n  validates :email, presence: true\nend"
      u.dependencies = [
        { type: :model, target: 'Role' },
        { type: :service, target: 'AuthService' }
      ]
    end
  end

  describe '#prepare' do
    it 'includes the type and identifier' do
      result = preparer.prepare(unit)
      expect(result).to include('[model] User')
    end

    it 'includes the namespace' do
      result = preparer.prepare(unit)
      expect(result).to include('namespace: Admin')
    end

    it 'includes the file path' do
      result = preparer.prepare(unit)
      expect(result).to include('file: app/models/user.rb')
    end

    it 'includes dependency names' do
      result = preparer.prepare(unit)
      expect(result).to include('dependencies: Role, AuthService')
    end

    it 'includes the source code' do
      result = preparer.prepare(unit)
      expect(result).to include('class User < ApplicationRecord')
    end

    context 'with a minimal unit' do
      let(:minimal_unit) do
        CodebaseIndex::ExtractedUnit.new(
          type: :service,
          identifier: 'PaymentService',
          file_path: 'app/services/payment_service.rb'
        ).tap { |u| u.source_code = 'class PaymentService; end' }
      end

      it 'omits namespace when nil' do
        result = preparer.prepare(minimal_unit)
        expect(result).not_to include('namespace:')
      end

      it 'omits dependencies when empty' do
        result = preparer.prepare(minimal_unit)
        expect(result).not_to include('dependencies:')
      end

      it 'includes type, identifier, and source' do
        result = preparer.prepare(minimal_unit)
        expect(result).to include('[service] PaymentService')
        expect(result).to include('class PaymentService; end')
      end
    end

    context 'with nil source code' do
      let(:empty_unit) do
        CodebaseIndex::ExtractedUnit.new(
          type: :job,
          identifier: 'CleanupJob',
          file_path: 'app/jobs/cleanup_job.rb'
        )
      end

      it 'uses empty string for content' do
        result = preparer.prepare(empty_unit)
        expect(result).to include('[job] CleanupJob')
      end
    end

    context 'with dependencies containing nil targets' do
      let(:unit_with_nil_deps) do
        CodebaseIndex::ExtractedUnit.new(
          type: :model,
          identifier: 'Post',
          file_path: 'app/models/post.rb'
        ).tap do |u|
          u.source_code = 'class Post; end'
          u.dependencies = [
            { type: :model, target: nil },
            { type: :model, target: 'Comment' }
          ]
        end
      end

      it 'filters out nil targets' do
        result = preparer.prepare(unit_with_nil_deps)
        expect(result).to include('dependencies: Comment')
        expect(result).not_to include('dependencies: , Comment')
      end
    end

    context 'with more than 10 dependencies' do
      let(:many_deps_unit) do
        deps = (1..15).map { |i| { type: :model, target: "Model#{i}" } }
        CodebaseIndex::ExtractedUnit.new(
          type: :controller,
          identifier: 'AdminController',
          file_path: 'app/controllers/admin_controller.rb'
        ).tap do |u|
          u.source_code = 'class AdminController; end'
          u.dependencies = deps
        end
      end

      it 'limits to first 10 dependencies' do
        result = preparer.prepare(many_deps_unit)
        expect(result).to include('Model10')
        expect(result).not_to include('Model11')
      end
    end
  end

  describe 'token limit enforcement' do
    let(:large_source) { 'x' * 50_000 }
    let(:large_unit) do
      CodebaseIndex::ExtractedUnit.new(
        type: :model,
        identifier: 'HugeModel',
        file_path: 'app/models/huge_model.rb'
      ).tap { |u| u.source_code = large_source }
    end

    it 'truncates text exceeding the token limit' do
      result = preparer.prepare(large_unit)
      estimated_tokens = (result.length / 3.5).ceil
      expect(estimated_tokens).to be <= 8192
    end

    context 'with a custom token limit' do
      subject(:small_preparer) { described_class.new(max_tokens: 100) }

      it 'enforces the custom limit' do
        result = small_preparer.prepare(large_unit)
        estimated_tokens = (result.length / 3.5).ceil
        expect(estimated_tokens).to be <= 100
      end
    end

    it 'does not truncate text within limits' do
      result = preparer.prepare(unit)
      expect(result).to include('validates :email, presence: true')
    end
  end

  describe '#prepare_chunks' do
    context 'when unit has no chunks' do
      it 'returns a single-element array' do
        result = preparer.prepare_chunks(unit)
        expect(result.length).to eq(1)
      end

      it 'returns the same result as #prepare' do
        chunks = preparer.prepare_chunks(unit)
        prepared = preparer.prepare(unit)
        expect(chunks.first).to eq(prepared)
      end
    end

    context 'when unit has chunks' do
      let(:chunked_unit) do
        CodebaseIndex::ExtractedUnit.new(
          type: :model,
          identifier: 'Order',
          file_path: 'app/models/order.rb'
        ).tap do |u|
          u.namespace = 'Commerce'
          u.source_code = 'class Order; end'
          u.chunks = [
            { chunk_index: 0, content: "# associations\nbelongs_to :user" },
            { chunk_index: 1, content: "# validations\nvalidates :total, numericality: true" }
          ]
        end
      end

      it 'returns one prepared text per chunk' do
        result = preparer.prepare_chunks(chunked_unit)
        expect(result.length).to eq(2)
      end

      it 'includes the prefix in each chunk' do
        result = preparer.prepare_chunks(chunked_unit)
        result.each do |text|
          expect(text).to include('[model] Order')
          expect(text).to include('namespace: Commerce')
        end
      end

      it 'includes the chunk content' do
        result = preparer.prepare_chunks(chunked_unit)
        expect(result[0]).to include('belongs_to :user')
        expect(result[1]).to include('validates :total')
      end
    end
  end
end
