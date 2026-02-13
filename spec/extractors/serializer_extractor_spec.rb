# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractors/serializer_extractor'

RSpec.describe CodebaseIndex::Extractors::SerializerExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers serializer files in app/serializers/' do
      create_file('app/serializers/user_serializer.rb', <<~RUBY)
        class UserSerializer < ActiveModel::Serializer
          attributes :id, :name, :email
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('UserSerializer')
      expect(units.first.type).to eq(:serializer)
    end

    it 'discovers blueprinter files in app/blueprinters/' do
      create_file('app/blueprinters/user_blueprint.rb', <<~RUBY)
        class UserBlueprint < Blueprinter::Base
          identifier :id
          field :name
          field :email
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('UserBlueprint')
    end

    it 'discovers decorator files in app/decorators/' do
      create_file('app/decorators/user_decorator.rb', <<~RUBY)
        class UserDecorator < Draper::Decorator
          delegate :name, :email, to: :object

          def full_title
            "Mr. \#{object.name}"
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('UserDecorator')
    end

    it 'skips non-serializer Ruby files' do
      create_file('app/serializers/base_concern.rb', <<~RUBY)
        module BaseConcern
          def some_helper
            true
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'discovers files in nested directories' do
      create_file('app/serializers/api/v2/user_serializer.rb', <<~RUBY)
        class Api::V2::UserSerializer < ActiveModel::Serializer
          attributes :id, :name
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Api::V2::UserSerializer')
      expect(units.first.namespace).to eq('Api::V2')
    end
  end

  # ── extract_serializer_file ──────────────────────────────────────────

  describe '#extract_serializer_file' do
    it 'extracts AMS serializer metadata' do
      path = create_file('app/serializers/post_serializer.rb', <<~RUBY)
        class PostSerializer < ActiveModel::Serializer
          attributes :id, :title, :body
          has_many :comments, serializer: CommentSerializer
          belongs_to :author

          def title
            object.title.upcase
          end
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:serializer)
      expect(unit.identifier).to eq('PostSerializer')
      expect(unit.metadata[:serializer_type]).to eq(:ams)
      expect(unit.metadata[:attributes]).to include('id', 'title', 'body')
      expect(unit.metadata[:associations].size).to eq(2)
      expect(unit.metadata[:custom_methods]).to include('title')
    end

    it 'extracts Blueprinter metadata' do
      path = create_file('app/blueprinters/order_blueprint.rb', <<~RUBY)
        class OrderBlueprint < Blueprinter::Base
          identifier :id
          field :total
          field :status

          view :extended do
            association :line_items, blueprint: LineItemBlueprint
          end

          view :full do
            field :notes
          end
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:serializer_type]).to eq(:blueprinter)
      expect(unit.metadata[:attributes]).to include('id', 'total', 'status')
      expect(unit.metadata[:views]).to include('extended', 'full')
    end

    it 'extracts Draper decorator metadata' do
      path = create_file('app/decorators/product_decorator.rb', <<~RUBY)
        class ProductDecorator < Draper::Decorator
          decorates :product
          delegate :name, :price, to: :object

          def formatted_price
            "$\#{object.price}"
          end
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:serializer_type]).to eq(:draper)
      expect(unit.metadata[:wrapped_model]).to eq('Product')
      expect(unit.metadata[:attributes]).to include('name', 'price')
      expect(unit.metadata[:custom_methods]).to include('formatted_price')
    end

    it 'returns nil for non-serializer files' do
      path = create_file('app/serializers/utility.rb', <<~RUBY)
        class Utility
          def self.format(data)
            data.to_json
          end
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_serializer_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'annotates source with header' do
      path = create_file('app/serializers/user_serializer.rb', <<~RUBY)
        class UserSerializer < ActiveModel::Serializer
          attributes :id, :name
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.source_code).to include('Serializer: UserSerializer')
      expect(unit.source_code).to include('Type: ams')
      expect(unit.source_code).to include('Wraps: User')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_serializer_file,
                    'app/serializers/post_serializer.rb',
                    <<~RUBY
                      class PostSerializer < ActiveModel::Serializer
                        attributes :id, :title
                        has_many :comments, serializer: CommentSerializer
                      end
                    RUBY

    it 'detects serializer-to-serializer dependencies' do
      path = create_file('app/serializers/post_serializer.rb', <<~RUBY)
        class PostSerializer < ActiveModel::Serializer
          has_many :comments, serializer: CommentSerializer
          belongs_to :author, serializer: AuthorSerializer
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      serializer_deps = unit.dependencies.select { |d| d[:type] == :serializer }
      targets = serializer_deps.map { |d| d[:target] }

      expect(targets).to include('CommentSerializer')
      expect(targets).to include('AuthorSerializer')
      expect(serializer_deps).to all(include(via: :serialization))
    end

    it 'detects service dependencies' do
      path = create_file('app/serializers/order_serializer.rb', <<~RUBY)
        class OrderSerializer < ActiveModel::Serializer
          attributes :id, :total

          def total
            PricingService.calculate(object)
          end
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('PricingService')
      expect(service_deps.first[:via]).to eq(:code_reference)
    end
  end

  # ── Serializer type detection ────────────────────────────────────────

  describe 'serializer type detection' do
    it 'detects ApplicationSerializer as AMS' do
      path = create_file('app/serializers/item_serializer.rb', <<~RUBY)
        class ItemSerializer < ApplicationSerializer
          attributes :id, :name
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.metadata[:serializer_type]).to eq(:ams)
    end

    it 'detects ApplicationDecorator as Draper' do
      path = create_file('app/decorators/item_decorator.rb', <<~RUBY)
        class ItemDecorator < ApplicationDecorator
          delegate :name, to: :object
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.metadata[:serializer_type]).to eq(:draper)
    end

    it 'detects BaseBlueprinter as Blueprinter' do
      path = create_file('app/blueprinters/item_blueprint.rb', <<~RUBY)
        class ItemBlueprint < BaseBlueprinter
          field :name
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.metadata[:serializer_type]).to eq(:blueprinter)
    end
  end

  # ── Wrapped model detection ──────────────────────────────────────────

  describe 'wrapped model detection' do
    it 'infers model from class name for serializers' do
      path = create_file('app/serializers/user_serializer.rb', <<~RUBY)
        class UserSerializer < ActiveModel::Serializer
          attributes :id
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.metadata[:wrapped_model]).to eq('User')
    end

    it 'infers model from class name for decorators' do
      path = create_file('app/decorators/order_decorator.rb', <<~RUBY)
        class OrderDecorator < Draper::Decorator
          delegate :id, to: :object
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.metadata[:wrapped_model]).to eq('Order')
    end

    it 'uses explicit decorates declaration for Draper' do
      path = create_file('app/decorators/special_decorator.rb', <<~RUBY)
        class SpecialDecorator < Draper::Decorator
          decorates :product
          delegate :name, to: :object
        end
      RUBY

      unit = described_class.new.extract_serializer_file(path)
      expect(unit.metadata[:wrapped_model]).to eq('Product')
    end
  end
end
