# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/caching_extractor'

RSpec.describe CodebaseIndex::Extractors::CachingExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'returns empty array when no files have cache calls' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers caching in controller files' do
      create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController < ApplicationController
          def show
            @product = Rails.cache.fetch("product/\#{params[:id]}") do
              Product.find(params[:id])
            end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:caching)
    end

    it 'discovers caching in model files' do
      create_file('app/models/product.rb', <<~RUBY)
        class Product < ApplicationRecord
          def cached_price
            Rails.cache.fetch("product_price/\#{id}") { price }
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.metadata[:file_type]).to eq(:model)
    end

    it 'discovers caching in view erb files' do
      create_file('app/views/products/index.html.erb', <<~ERB)
        <% cache @products do %>
          <%= render @products %>
        <% end %>
      ERB

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.metadata[:file_type]).to eq(:view)
    end

    it 'skips files with no cache calls' do
      create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController < ApplicationController
          def index
            @products = Product.all
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to eq([])
    end

    it 'discovers multiple files with caching' do
      create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("p/\#{params[:id]}") { Product.find(params[:id]) }
          end
        end
      RUBY

      create_file('app/models/user.rb', <<~RUBY)
        class User
          def stats
            Rails.cache.read("user_stats/\#{id}")
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end
  end

  # ── extract_caching_file ─────────────────────────────────────────────

  describe '#extract_caching_file' do
    it 'extracts a file with Rails.cache.fetch' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("product/1") { Product.find(1) }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit).not_to be_nil
      expect(unit.type).to eq(:caching)
      expect(unit.file_path).to eq(path)
    end

    it 'returns nil for files with no cache calls' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def index
            @products = Product.all
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit).to be_nil
    end

    it 'returns nil for non-existent files' do
      unit = described_class.new.extract_caching_file('/nonexistent/path.rb', :controller)
      expect(unit).to be_nil
    end

    it 'sets identifier to the relative path' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("p") { 1 }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.identifier).to eq('app/controllers/products_controller.rb')
    end

    it 'sets source_code with annotation header' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("p") { 1 }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.source_code).to include('# ║ Caching:')
      expect(unit.source_code).to include('Rails.cache.fetch')
    end

    it 'sets namespace to nil' do
      path = create_file('app/models/user.rb', <<~RUBY)
        class User
          def stats; Rails.cache.read("k"); end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      expect(unit.namespace).to be_nil
    end

    it 'all dependencies have :via key' do
      path = create_file('app/controllers/orders_controller.rb', <<~RUBY)
        class OrdersController
          def show
            Rails.cache.fetch("order/1") { OrderService.find(1) }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'infers file_type from path when not passed' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("p") { 1 }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path)
      expect(unit.metadata[:file_type]).to eq(:controller)
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'detects Rails.cache.fetch as low_level strategy' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("key") { compute }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.metadata[:cache_strategy]).to eq(:low_level)
    end

    it 'detects caches_action as action strategy' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController < ActionController::Base
          caches_action :show
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.metadata[:cache_strategy]).to eq(:action)
    end

    it 'detects cache do block as fragment strategy' do
      path = create_file('app/views/products/show.html.erb', <<~ERB)
        <% cache @product do %>
          <%= @product.name %>
        <% end %>
      ERB

      unit = described_class.new.extract_caching_file(path, :view)
      expect(unit.metadata[:cache_strategy]).to eq(:fragment)
    end

    it 'detects mixed strategy when multiple types present' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController < ActionController::Base
          caches_action :show

          def index
            Rails.cache.fetch("products") { Product.all }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.metadata[:cache_strategy]).to eq(:mixed)
    end

    it 'populates cache_calls array' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("p") { 1 }
            Rails.cache.write("q", 2)
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.metadata[:cache_calls]).to be_an(Array)
      expect(unit.metadata[:cache_calls].size).to be >= 2
    end

    it 'includes cache call types in cache_calls' do
      path = create_file('app/models/user.rb', <<~RUBY)
        class User
          def cached_data
            Rails.cache.fetch("user/1") { load_data }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      fetch_call = unit.metadata[:cache_calls].find { |c| c[:type] == :fetch }
      expect(fetch_call).not_to be_nil
    end

    it 'extracts TTL from expires_in option' do
      path = create_file('app/models/user.rb', <<~RUBY)
        class User
          def cached_data
            Rails.cache.fetch("user/1", expires_in: 1.hour) { load_data }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      fetch_call = unit.metadata[:cache_calls].find { |c| c[:type] == :fetch }
      expect(fetch_call[:ttl]).to include('1.hour')
    end

    it 'sets file_type correctly' do
      path = create_file('app/models/product.rb', <<~RUBY)
        class Product
          def price_key; Rails.cache.fetch("k") { 1 }; end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      expect(unit.metadata[:file_type]).to eq(:model)
    end

    it 'includes loc count' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("p") { 1 }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      expect(unit.metadata[:loc]).to be_a(Integer)
      expect(unit.metadata[:loc]).to be > 0
    end

    it 'includes all expected metadata keys' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show; Rails.cache.fetch("p") { 1 }; end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      meta = unit.metadata

      expect(meta).to have_key(:cache_calls)
      expect(meta).to have_key(:cache_strategy)
      expect(meta).to have_key(:file_type)
      expect(meta).to have_key(:loc)
    end

    it 'detects cache_key pattern' do
      path = create_file('app/models/product.rb', <<~RUBY)
        class Product
          def cache_key
            "product/\#{id}/\#{updated_at}"
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      expect(unit).not_to be_nil
      cache_key_call = unit.metadata[:cache_calls].find { |c| c[:type] == :cache_key }
      expect(cache_key_call).not_to be_nil
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('app/controllers/products_controller.rb', <<~RUBY)
        class ProductsController
          def show
            Rails.cache.fetch("product/1") { Product.find(1) }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :controller)
      hash = unit.to_h

      expect(hash[:type]).to eq(:caching)
      expect(hash[:identifier]).to eq('app/controllers/products_controller.rb')
      expect(hash[:source_code]).to include('Rails.cache.fetch')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('caching')
    end
  end
end
