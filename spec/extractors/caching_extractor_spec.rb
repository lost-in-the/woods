# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'active_support/core_ext/object/blank'
require 'woods/model_name_cache'
require 'woods/extractors/caching_extractor'
require 'woods/extractor'

RSpec.describe Woods::Extractors::CachingExtractor do
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

    it 'discovers fragment caching in view haml files' do
      create_file('app/views/widgets/index.html.haml', <<~HAML)
        - cache @widgets do
          = render @widgets
      HAML

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to eq(['app/views/widgets/index.html.haml'])
      expect(units.first.metadata[:file_type]).to eq(:view)
      expect(units.first.metadata[:cache_strategy]).to eq(:fragment)
    end

    it 'discovers jbuilder cache! blocks in view jbuilder files' do
      create_file('app/views/ledgers/show.json.jbuilder', <<~JBUILDER)
        json.cache! ['v1', @ledger], expires_in: 10.minutes do
          json.extract! @ledger, :id, :balance
        end
      JBUILDER

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to eq(['app/views/ledgers/show.json.jbuilder'])
      expect(units.first.metadata[:cache_strategy]).to eq(:fragment)
    end

    it 'does not scan slim views, which have no template engine' do
      create_file('app/views/widgets/index.html.slim', "- cache @widgets do\n  = render @widgets\n")

      expect(described_class.new.extract_all).to eq([])
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

    # #201 — key/TTL parsing ran against the whole source, so every entry got
    # the first call's key and the first expires_in in the file.
    it 'attributes keys and TTLs to each call individually' do
      path = create_file('app/models/report.rb', <<~RUBY)
        class Report
          def hourly
            Rails.cache.fetch("report/hourly", expires_in: 1.hour) { compute_hourly }
          end

          def daily
            Rails.cache.fetch("report/daily", expires_in: 12.hours) { compute_daily }
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      fetch_calls = unit.metadata[:cache_calls].select { |c| c[:type] == :fetch }

      expect(fetch_calls.size).to eq(2)
      expect(fetch_calls).to contain_exactly(
        { type: :fetch, key_pattern: '"report/hourly"', ttl: '1.hour', options: { expires_in: '1.hour' } },
        { type: :fetch, key_pattern: '"report/daily"', ttl: '12.hours', options: { expires_in: '12.hours' } }
      )
    end

    it 'does not give a call without expires_in a neighboring call TTL' do
      path = create_file('app/models/report.rb', <<~RUBY)
        class Report
          def cached
            Rails.cache.fetch("report/cached", expires_in: 1.hour) { compute }
          end

          def latest
            Rails.cache.read("report/latest")
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      read_call = unit.metadata[:cache_calls].find { |c| c[:type] == :read }

      expect(read_call[:key_pattern]).to eq('"report/latest"')
      expect(read_call[:ttl]).to be_nil
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

    it 'counts cache_key and cache_key_with_version called on a receiver' do
      path = create_file('app/models/ledger.rb', <<~RUBY)
        class Ledger
          def digest_key = "\#{owner.cache_key}/\#{entries.cache_key_with_version}"
          def stamp = account&.cache_version
        end
      RUBY

      types = described_class.new.extract_caching_file(path, :model).metadata[:cache_calls].map { |c| c[:type] }
      expect(types).to eq(%i[cache_key cache_key cache_version])
    end

    {
      'jbuilder' => ['app/views/widgets/show.json.jbuilder', "json.cache! cache_key do\n  json.id 1\nend\n"],
      'erb' => ['app/views/widgets/show.html.erb', "<% cache cache_key do %>\n  <p>hi</p>\n<% end %>\n"],
      'haml' => ['app/views/widgets/show.html.haml', "- cache cache_version do\n  %p hi\n"]
    }.each do |engine, (relative, source)|
      it "does not count a bare cache_key/cache_version argument in a #{engine} view as a call" do
        path = create_file(relative, source)

        calls = described_class.new.extract_caching_file(path, :view).metadata[:cache_calls]
        expect(calls.map { |c| c[:type] }).to eq([:fragment])
      end
    end

    it 'keeps an implicit-self cache_key call as the only cache signal of a model' do
      path = create_file('app/models/ledger.rb', <<~'RUBY')
        class Ledger
          def archive_path
            "archives/#{cache_key}/#{cache_key_with_version}/#{cache_version}.csv"
          end
        end
      RUBY

      unit = described_class.new.extract_caching_file(path, :model)
      expect(unit.metadata[:cache_calls].map { |c| c[:type] }).to eq(%i[cache_key cache_key cache_version])
    end

    it 'does not count a bare cache_key argument nested in a cache key or a Rails.cache call' do
      path = create_file('app/models/ledger.rb', <<~RUBY)
        class Ledger
          def totals = Rails.cache.fetch(cache_key) { compute }
          def summary = Rails.cache.read([cache_key_with_version, "summary"])
        end
      RUBY

      types = described_class.new.extract_caching_file(path, :model).metadata[:cache_calls].map { |c| c[:type] }
      expect(types).to eq(%i[fetch read])
    end

    # An argument range in different units from the match offsets ends short
    # of (or runs past) a multibyte key's arguments, miscounting the bare key
    # inside them or the implicit-self call in the block.
    it 'measures argument ranges in the units of the match offsets, after a multibyte key' do
      path = create_file('app/views/widgets/show.html.erb',
                         "<% cache ['☃☃☃☃☃☃', cache_key] do %><%= cache_key %>\n<% end %>\n")

      calls = described_class.new.extract_caching_file(path, :view).metadata[:cache_calls]
      expect(calls.map { |c| c[:type] }).to eq(%i[fragment cache_key])
    end

    it 'still counts a receiver cache_key call inside cache call arguments' do
      path = create_file('app/views/ledgers/show.json.jbuilder', <<~JBUILDER)
        json.cache! [ledger.cache_key, cache_key], expires_in: 1.hour do
          json.id ledger.id
        end
      JBUILDER

      types = described_class.new.extract_caching_file(path, :view).metadata[:cache_calls].map { |c| c[:type] }
      expect(types).to eq(%i[fragment cache_key])
    end
  end

  # ── Cache call arguments ─────────────────────────────────────────────

  # key_pattern is the call's own key expression (source text); options holds
  # the literal-valued cache options. ttl keeps any expires_in expression.
  describe 'cache call arguments' do
    def calls_for(relative, source)
      described_class.new.extract_caching_file(create_file(relative, source)).metadata[:cache_calls]
    end

    it 'captures the key of a haml fragment cache' do
      calls = calls_for('app/views/shipments/show.html.haml', <<~HAML)
        - cache [shipment.label_images_cache_key, "images"] do
          = render shipment.labels
      HAML

      expect(calls).to eq([{ type: :fragment, key_pattern: '[shipment.label_images_cache_key, "images"]',
                             ttl: nil, options: {} }])
    end

    it 'captures the key and literal options of a jbuilder cache! block' do
      calls = calls_for('app/views/widgets/show.json.jbuilder', <<~JBUILDER)
        json.cache! [widget, 'v2'], expires_in: 1.hour do
          json.id widget.id
        end
      JBUILDER

      expect(calls).to eq([{ type: :fragment, key_pattern: "[widget, 'v2']", ttl: '1.hour',
                             options: { expires_in: '1.hour' } }])
    end

    it 'captures the key and literal options of an erb fragment cache' do
      calls = calls_for('app/views/widgets/index.html.erb', <<~ERB)
        <% cache [@widgets, 'v3'], expires_in: 10.minutes, race_condition_ttl: 30.seconds, if: :fresh? do -%>
          <%= render @widgets %>
        <% end %>
      ERB

      expect(calls).to eq([{ type: :fragment, key_pattern: "[@widgets, 'v3']", ttl: '10.minutes',
                             options: { expires_in: '10.minutes', race_condition_ttl: '30.seconds', if: ':fresh?' } }])
    end

    it 'keeps a computed expires_in as ttl but leaves non-literal options out' do
      calls = calls_for('app/views/widgets/show.html.erb', <<~ERB)
        <% cache @widget, expires_in: ttl_for(@widget), unless: current_user.admin? do %>
          <p>hi</p>
        <% end %>
      ERB

      expect(calls).to eq([{ type: :fragment, key_pattern: '@widget', ttl: 'ttl_for(@widget)', options: {} }])
    end

    it 'takes the key after the condition for conditional fragment caches' do
      erb = calls_for('app/views/widgets/index.html.erb', "<% cache_if feature_on?, [@widget] do %>\n<% end %>\n")
      jbuilder = calls_for('app/views/widgets/show.json.jbuilder', <<~JBUILDER)
        json.cache_if! admin?, [widget, 'admin'], expires_in: 5.minutes do
          json.id widget.id
        end
      JBUILDER

      expect(erb).to eq([{ type: :fragment, key_pattern: '[@widget]', ttl: nil, options: {} }])
      expect(jbuilder).to eq([{ type: :fragment, key_pattern: "[widget, 'admin']", ttl: '5.minutes',
                                options: { expires_in: '5.minutes' } }])
    end

    it 'keeps interpolation and brackets inside a Rails.cache key whole' do
      calls = calls_for('app/models/ledger.rb', <<~'RUBY')
        class Ledger
          def balance
            Rails.cache.fetch("ledger/#{params[:id]}/balance", expires_in: 5.minutes) { compute }
          end
        end
      RUBY

      expect(calls).to eq([{ type: :fetch, key_pattern: "\"ledger/\#{params[:id]}/balance\"", ttl: '5.minutes',
                             options: { expires_in: '5.minutes' } }])
    end

    it 'reads arguments that span several lines' do
      calls = calls_for('app/models/ledger.rb', <<~RUBY)
        class Ledger
          def totals
            Rails.cache.fetch(
              ["ledger", id, "totals"],
              expires_in: 1.day,
              race_condition_ttl: 10
            ) { compute }
          end
        end
      RUBY

      expect(calls).to eq([{ type: :fetch, key_pattern: '["ledger", id, "totals"]', ttl: '1.day',
                             options: { expires_in: '1.day', race_condition_ttl: '10' } }])
    end

    it 'reads a call that shares its line with the rest of a one-line method' do
      calls = calls_for('app/models/ledger.rb', <<~RUBY)
        class Ledger
          def balance; Rails.cache.fetch("ledger/balance", expires_in: 1.hour) { compute }; end
        end
      RUBY

      expect(calls).to eq([{ type: :fetch, key_pattern: '"ledger/balance"', ttl: '1.hour',
                             options: { expires_in: '1.hour' } }])
    end

    it 'keeps a key whose string mentions cache as one fragment call' do
      erb = calls_for('app/views/widgets/show.html.erb', <<~ERB)
        <% cache [@widget, "cache me now"] do %>
        <% end %>
      ERB
      haml = calls_for('app/views/widgets/show.html.haml', <<~'HAML')
        - cache [@widget, 'cache it', "say \"cache me\""] do
          %p hi
      HAML

      expect(erb).to eq([{ type: :fragment, key_pattern: '[@widget, "cache me now"]', ttl: nil, options: {} }])
      expect(haml).to eq([{ type: :fragment, key_pattern: %q([@widget, 'cache it', "say \\"cache me\\""]), ttl: nil,
                            options: {} }])
    end

    it 'does not read a fragment cache out of another cache call arguments' do
      calls = calls_for('app/models/ledger.rb', <<~RUBY)
        class Ledger
          def notes = Rails.cache.fetch([id, "cache me do"]) { compute }
        end
      RUBY

      expect(calls.map { |c| c[:type] }).to eq([:fetch])
    end

    {
      'output tag in an attribute with a fallback' => '<i data-token="<%= Rails.cache.read(KEY) || fallback %>"></i>',
      'ternary' => '<i data-token="<%= Rails.cache.read(KEY) ? token : nil %>"></i>',
      'chained call' => '<i data-token="<%= Rails.cache.read(KEY).to_s %>"></i>',
      'safe navigation' => '<i data-token="<%= Rails.cache.read(KEY)&.token %>"></i>',
      'elsif condition' => "<% if a %>\n<% elsif Rails.cache.read(KEY).present? %>\n<% end %>",
      'compound condition' => "<% if Rails.cache.read(KEY) && ready? %>\n<% end %>",
      'chained block' => '<%= Rails.cache.fetch(KEY) { 1 }.to_s %>'
    }.each do |shape, template|
      it "reads the key of a call inside a larger expression: #{shape}" do
        key = "\"widget-token-\#{current_owner.id}\""
        calls = calls_for('app/views/widgets/show.html.erb', "#{template.sub('KEY', key)}\n")

        expect(calls.map { |c| c[:key_pattern] }).to eq([key])
      end
    end

    it 'truncates a long key expression to 120 characters' do
      key = "[#{Array.new(40) { |i| "part_#{i}" }.join(', ')}]"
      calls = calls_for('app/views/widgets/index.html.haml', "- cache #{key} do\n  %p hi\n")

      expect(calls.first[:key_pattern]).to eq(key[0, 120])
    end
  end

  # ── Source encoding ──────────────────────────────────────────────────

  # Under a POSIX locale a bare File.read tags source as US-ASCII, and a
  # multibyte template then fails the byte-offset scan.
  describe 'source encoding' do
    it 'reads a multibyte source the same under a POSIX default external encoding' do
      path = create_file('app/views/widgets/show.html.haml', <<~HAML)
        -# Ünïcødé ☃ comment
        - cache [@widget, "☃"] do
          %p= Rails.cache.read("widget/☃")
      HAML

      original_encoding = Encoding.default_external
      original_verbose = $VERBOSE
      begin
        $VERBOSE = nil # Ruby warns when the default external encoding is reassigned.
        Encoding.default_external = Encoding::US_ASCII
        calls = described_class.new.extract_caching_file(path)&.metadata&.fetch(:cache_calls)
      ensure
        Encoding.default_external = original_encoding
        $VERBOSE = original_verbose
      end

      expect(calls&.map { |c| c[:key_pattern] }).to eq(['"widget/☃"', '[@widget, "☃"]'])
    end
  end

  # ── Custom cache stores ──────────────────────────────────────────────

  # A store a file obtains itself (from `.cache_store`,
  # `ActiveSupport::Cache.lookup_store`, or `ActiveSupport::Cache::*Store.new`)
  # is a cache like Rails.cache; its calls carry the receiver as :store.
  describe 'custom cache stores' do
    def extract(source)
      described_class.new.extract_caching_file(create_file('app/models/widget.rb', source))
    end

    it 'records calls on a local assigned from cache_store' do
      unit = extract(<<~'RUBY')
        class Widget
          def sync
            store = WidgetConnection.cache_store
            store.write("widget/#{id}", payload, expires_in: 10.minutes)
            store.fetch("widget/#{id}")
          end
        end
      RUBY

      key = "\"widget/\#{id}\""
      origin = 'WidgetConnection.cache_store'
      write = { type: :write, key_pattern: key, ttl: '10.minutes', options: { expires_in: '10.minutes' },
                store: 'store', store_origin: origin }
      fetch = { type: :fetch, key_pattern: key, ttl: nil, options: {}, store: 'store', store_origin: origin }
      expect(unit.metadata[:cache_calls]).to eq([write, fetch])
      expect(unit.metadata[:cache_strategy]).to eq(:low_level)
    end

    it 'records calls on a constant assigned from lookup_store' do
      unit = extract(<<~'RUBY')
        class Ledger
          LEDGER_CACHE = ActiveSupport::Cache.lookup_store(:memory_store)
          def balance = LEDGER_CACHE.read("ledger/#{id}")
          def reset = LEDGER_CACHE.delete("ledger/#{id}")
          def cached? = LEDGER_CACHE.exist?("ledger/#{id}")
        end
      RUBY

      calls = unit.metadata[:cache_calls]
      expect(calls.map { |c| c[:type] }).to eq(%i[read delete exist])
      expect(calls.map { |c| c[:store] }.uniq).to eq(['LEDGER_CACHE'])
      expect(calls.map { |c| c[:store_origin] }.uniq).to eq(['ActiveSupport::Cache.lookup_store(:memory_store)'])
    end

    it 'records calls on a memoizing method and its ivar' do
      unit = extract(<<~'RUBY')
        class Shipment
          def label_cache
            @label_cache ||= ActiveSupport::Cache::MemoryStore.new(size: 1.megabyte)
          end

          def label = label_cache.fetch("shipment/#{id}/label", expires_in: 1.hour) { render_label }
          def clear = @label_cache.delete("shipment/#{id}/label")
        end
      RUBY

      calls = unit.metadata[:cache_calls]
      expect(calls.map { |c| [c[:type], c[:store], c[:ttl]] }).to eq([[:fetch, 'label_cache', '1.hour'],
                                                                      [:delete, '@label_cache', nil]])
      expect(calls.map { |c| c[:store_origin] }.uniq).to eq(['ActiveSupport::Cache::MemoryStore.new(size: 1.megabyte)'])
    end

    it 'records a call chained straight onto the store expression' do
      calls = extract("WidgetConnection.cache_store.write('widget/all', 1)\n").metadata[:cache_calls]

      expect(calls).to eq([{ type: :write, key_pattern: "'widget/all'", ttl: nil, options: {},
                             store: 'WidgetConnection.cache_store', store_origin: 'WidgetConnection.cache_store' }])
    end

    it 'orders store calls after Rails.cache calls and excludes a bare key method argument' do
      calls = extract(<<~RUBY).metadata[:cache_calls]
        class Widget
          def totals = Rails.cache.fetch("totals") { compute }
          def local = (store = WidgetConnection.cache_store).fetch(cache_key)
        end
      RUBY

      expect(calls.map { |c| c[:type] }).to eq(%i[fetch fetch])
      expect(calls.last.values_at(:store, :store_origin)).to eq(['(store = WidgetConnection.cache_store)'] * 2)
    end

    it 'records an injected store with a factory fallback read through attr_reader' do
      unit = extract(<<~RUBY)
        class ThrottleCache
          attr_reader :store, :ttl
          def initialize(store: nil)
            @store = store || LedgerConnection.cache_store(namespace: self.class.to_s)
          end
          def remember_failure(key) = store.write(key, FAILURE_MARKER, expires_in: FAILURE_TTL)
          def remember(key, result) = store.write(key, Snapshot.dump(result), expires_in: TTL)
          def lookup(key) = store.read(key)
        end
      RUBY

      calls = unit.metadata[:cache_calls]
      expect(calls.map { |c| [c[:type], c[:key_pattern], c[:ttl], c[:store]] }).to eq(
        [[:write, 'key', 'FAILURE_TTL', 'store'], [:write, 'key', 'TTL', 'store'], [:read, 'key', nil, 'store']]
      )
      origin = 'LedgerConnection.cache_store(namespace: self.class.to_s)'
      expect(calls.map { |c| c[:store_origin] }.uniq).to eq([origin])
      expect(unit.metadata[:cache_strategy]).to eq(:low_level)
    end

    it 'treats a cache_store factory call with arguments as a store' do
      calls = extract(<<~RUBY).metadata[:cache_calls]
        class Widget
          def lookup(key)
            store = WidgetConnection.cache_store(namespace: "widgets")
            store.read(key)
          end
        end
      RUBY

      expect(calls.map { |c| c.values_at(:type, :store, :store_origin) }).to eq(
        [[:read, 'store', 'WidgetConnection.cache_store(namespace: "widgets")']]
      )
    end

    it 'treats a fallback with a store on either side as a store' do
      calls = extract(<<~RUBY).metadata[:cache_calls]
        class Widget
          def initialize(given) = @cache = given || ActiveSupport::Cache.lookup_store(:memory_store)
          def other(given) = (given or WidgetConnection.cache_store).fetch("widget")
          def lookup(key) = @cache.read(key)
        end
      RUBY

      expect(calls.map { |c| c.values_at(:type, :store, :store_origin) }).to eq(
        [[:fetch, '(given or WidgetConnection.cache_store)', '(given or WidgetConnection.cache_store)'],
         [:read, '@cache', 'ActiveSupport::Cache.lookup_store(:memory_store)']]
      )
    end

    it 'follows readers, hand-written readers, and aliases of a bound instance variable' do
      calls = extract(<<~RUBY).metadata[:cache_calls]
        class Widget
          attr_accessor :cache
          attr_reader :other
          alias_method "kv", "cache"
          alias kv2 kv
          def initialize = @cache = WidgetConnection.cache_store
          def backing = @cache
          def a(key) = cache.read(key)
          def b(key) = kv.read(key)
          def c(key) = kv2.read(key)
          def d(key) = backing.read(key)
          def e(key) = other.read(key)
        end
      RUBY

      expect(calls.map { |c| c[:store] }).to eq(%w[cache kv kv2 backing])
      expect(calls.map { |c| c[:store_origin] }.uniq).to eq(['WidgetConnection.cache_store'])
    end

    it 'takes the first binding in source order as the origin, and truncates it' do
      long = "WidgetConnection.cache_store(namespace: #{'x' * 150})"
      calls = extract(<<~RUBY).metadata[:cache_calls]
        class Widget
          def first = @cache = #{long}
          def second = @cache = ActiveSupport::Cache.lookup_store(:memory_store)
          def lookup(key) = @cache.read(key)
        end
      RUBY

      expect(calls.map { |c| c[:store_origin] }).to eq([long[0, 120]])
    end

    it 'ignores write-like calls on receivers that are not cache stores' do
      unit = extract(<<~RUBY)
        class Widget
          def store = Store.first
          def settings = Rails.application.config.cache_store
          def persist
            record = Store.find(id)
            record.write("widget", 1)
            store.fetch("widget")
            settings.fetch(0)
          end
        end
      RUBY

      expect(unit).to be_nil
    end

    it 'ignores commented-out store calls' do
      unit = extract(<<~RUBY)
        class Widget
          CACHE = ActiveSupport::Cache.lookup_store(:memory_store)
          # CACHE.write("widget", 1)
        end
      RUBY

      expect(unit).to be_nil
    end
  end

  # ── Comments ─────────────────────────────────────────────────────────

  # Commented-out code never runs, so a cache call inside a comment is not a
  # cache call. Each engine's comment forms are blanked before scanning.
  describe 'commented-out cache calls' do
    def extract(relative, source)
      described_class.new.extract_caching_file(create_file(relative, source))
    end

    def types(relative, source)
      extract(relative, source).metadata[:cache_calls].map { |c| c[:type] }
    end

    it 'ignores ERB comment tags, including multi-line ones' do
      unit = extract('app/views/widgets/index.html.erb', <<~ERB)
        <%# cache @widgets do %>
        <%#
          cache [@widget, 'v1'] do
        %>
        <p>no cache</p>
      ERB

      expect(unit).to be_nil
    end

    it 'ignores Ruby comments inside ERB code tags' do
      expect(extract('app/views/widgets/index.html.erb', "<% # cache @widgets do %>\n")).to be_nil
    end

    it 'keeps a real ERB call next to a commented one' do
      expect(types('app/views/widgets/index.html.erb', <<~ERB)).to eq([:fragment])
        <%# cache @old do %>
        <% cache [@widget, 'v1'] do %>
        <% end %>
      ERB
    end

    it 'ignores a HAML silent comment and its indented block' do
      expect(types('app/views/widgets/index.html.haml', <<~HAML)).to eq([:fragment])
        -# cache @old do
        -#
          - cache @older do
            = render @older

          - cache @oldest do
        - cache [@widget, 'v1'] do
          = render @widget
        - # cache @ruby_comment do
      HAML
    end

    it 'ignores Ruby line comments and =begin blocks in a model' do
      unit = extract('app/models/ledger.rb', <<~RUBY)
        class Ledger
          # Rails.cache.fetch("ledger/old") { compute }
          # "\#{cache_key}/archived"
        =begin
          Rails.cache.write("ledger/older", 1)
          caches_action :show
        =end
          def total = compute
        end
      RUBY

      expect(unit).to be_nil
    end

    it 'keeps a real Ruby call before a trailing comment' do
      expect(types('app/models/ledger.rb', <<~RUBY)).to eq([:fetch])
        class Ledger
          def total = Rails.cache.fetch("ledger/total") { compute } # Rails.cache.read("ledger/x")
        end
      RUBY
    end

    it 'ignores commented jbuilder cache blocks' do
      expect(types('app/views/widgets/show.json.jbuilder', <<~JBUILDER)).to eq([:fragment])
        # json.cache! ['old', widget] do
        json.cache! ['v2', widget] do
          json.id widget.id
        end
      JBUILDER
    end

    it 'leaves a commented caches_action out of the strategy' do
      unit = extract('app/controllers/widgets_controller.rb', <<~RUBY)
        class WidgetsController
          # caches_action :index
          def index = Rails.cache.fetch("widgets") { load }
        end
      RUBY

      expect(unit.metadata[:cache_strategy]).to eq(:low_level)
    end

    it 'reads the right key after a multibyte comment' do
      calls = extract('app/views/widgets/show.html.haml', <<~HAML).metadata[:cache_calls]
        -# Ünïcødé ☃ cache @old do
        - cache [@widget, "☃"] do
          %p hi
      HAML

      expect(calls).to eq([{ type: :fragment, key_pattern: '[@widget, "☃"]', ttl: nil, options: {} }])
    end
  end

  # ── Adversarial input complexity ─────────────────────────────────────

  # Every scan must stay linear. Ruby 3.2+ fails a slow match through
  # Regexp.timeout; older Rubies (no regex memoization, the real exposure)
  # rely on the wall-clock budget.
  describe 'adversarial input complexity' do
    # Only this extractor's own scans are timed here. The shared dependency
    # scan has its own budget in dependency_scan_complexity_spec.rb.
    before { allow_any_instance_of(described_class).to receive(:extract_dependencies).and_return([]) }

    def within_budget(&block)
      return Timeout.timeout(5, &block) unless Regexp.respond_to?(:timeout=)

      previous = Regexp.timeout
      Regexp.timeout = 1.0
      begin
        Timeout.timeout(5, &block)
      ensure
        Regexp.timeout = previous
      end
    end

    repeats = 50_000
    {
      'cache tokens with no do' => 'cache ' * repeats,
      'cache then a long blank run' => "cache#{' ' * repeats}x",
      'cache then mixed blanks' => "cache \t" * repeats,
      'conditional cache tokens' => 'cache_if ' * repeats,
      'near-miss do' => 'cache dox ' * repeats,
      'json.cache without a bang' => 'json.cache ' * repeats,
      'Rails.cache.fetch then blanks' => "Rails.cache.fetch#{' ' * repeats}x",
      'cache_key-prefixed words' => 'cache_keyx ' * repeats,
      'cache inside an open string' => 'cache "cache ' * repeats,
      'cache inside closed strings' => 'cache "cache " ' * repeats,
      'unclosed quotes after cache' => %(cache "x cache 'y ) * repeats,
      'escaped quotes after cache' => 'cache "\\" cache ' * repeats,
      'mixed quotes after cache' => %(cache "' cache '" ) * repeats,
      'backslash quote outside a string' => %(cache \\" cache ) * repeats,
      'backslash runs around quotes' => %(cache "\\\\" cache \\' cache ) * repeats
    }.each do |label, input|
      it "matches every cache pattern in linear time: #{label}" do
        within_budget do
          described_class::CACHE_PATTERNS.each_value { |pattern| pattern.match?(input) }
        end
      end
    end

    it 'extracts 10k near-miss lines in linear time' do
      path = create_file('app/views/widgets/index.html.erb',
                         "#{"<% cache [@widget, 'v1'] dox %>\n" * 10_000}<% cache @widget do %>\n<% end %>\n")

      unit = within_budget { described_class.new.extract_caching_file(path, :view) }
      expect(unit.metadata[:cache_calls].size).to eq(1)
    end

    it 'extracts 10k fragment caches keyed by a bare cache_key in linear time' do
      path = create_file('app/views/widgets/index.html.erb', "<% cache [cache_key, 'v1'] do %><% end %>\n" * 10_000)

      unit = within_budget { described_class.new.extract_caching_file(path, :view) }
      expect(unit.metadata[:cache_calls].map { |c| c[:type] }.uniq).to eq([:fragment])
    end

    erb_call = "\n<% cache @w do %>"
    haml_call = "- cache @w do\n"
    {
      'ERB comment tags' => ['app/views/w/a.html.erb', '<%# cache @w do %>' * repeats, erb_call],
      'ERB tags opening on blanks' => ['app/views/w/b.html.erb', "<% #{' ' * repeats}x %>" * 3, erb_call],
      'ERB tag openers' => ['app/views/w/c.html.erb', '<% ' * repeats, "%>#{erb_call}"],
      'HAML silent comment blocks' => ['app/views/w/d.html.haml', "-# c\n  - cache @w do\n" * 10_000, haml_call],
      'HAML deep indentation' => ['app/views/w/e.html.haml', "-#\n#{' ' * repeats}- cache @w do\n", haml_call],
      'Ruby comment lines' => ['app/models/w.rb', "# Rails.cache.fetch('k') { 1 }\n" * repeats,
                               "Rails.cache.fetch('k') { 1 }\n"],
      '=begin blocks' => ['app/models/x.rb', "=begin\nRails.cache.read('k')\n=end\n" * 10_000,
                          "Rails.cache.read('k')\n"]
    }.each do |label, (relative, noise, call)|
      it "blanks comments in linear time: #{label}" do
        path = create_file(relative, noise + call)

        unit = within_budget { described_class.new.extract_caching_file(path) }
        expect(unit.metadata[:cache_calls].size).to eq(1)
      end
    end

    # MatchData offsets on a UTF-8 string are counted from its start, so a
    # match loop has to work in bytes to stay linear.
    it 'finds 50k key method calls in a multibyte file in linear time' do
      path = create_file('app/models/ledger.rb', "☃ ledger.cache_key\n" * repeats)

      unit = within_budget { described_class.new.extract_caching_file(path) }
      expect(unit.metadata[:cache_calls].size).to eq(repeats)
    end

    it 'reads 10k fragment calls in a multibyte file in linear time' do
      path = create_file('app/views/w/g.html.erb', "<% cache [@w, '☃'] do %><% end %>\n" * 10_000)

      unit = within_budget { described_class.new.extract_caching_file(path) }
      expect(unit.metadata[:cache_calls].map { |c| c[:key_pattern] }.uniq).to eq(["[@w, '☃']"])
    end

    store = "CACHE = ActiveSupport::Cache.lookup_store(:memory_store)\n"
    {
      'calls on a custom store' => [store + ("CACHE.write('k', 1)\n" * repeats), repeats],
      'store bindings' => ["#{Array.new(repeats) { |i| "s#{i} = Widget.cache_store\n" }.join}s1.read(1)\n", 1],
      'deep nesting near a store' => ["#{store}x = #{'[' * 5_000}#{']' * 5_000}\nCACHE.read(1)\n", 1],
      'a long call chain off a store' => ["#{store}CACHE#{'.itself' * repeats}.read(1)\nCACHE.read(1)\n", 1],
      'write calls on other receivers' => ["#{store}#{"record.write(1)\n" * repeats}CACHE.read(1)\n", 1],
      'an alias chain declared in reverse' => [
        "#{store}#{Array.new(repeats) { |i| "alias_method :a#{repeats - i}, :a#{repeats - i - 1}\n" }.join}" \
        "def a0 = CACHE\na#{repeats}.read(1)\n", 1
      ],
      'attr readers' => ["@kv = Widget.cache_store\n#{"attr_reader :kv\n" * repeats}kv.read(1)\n", 1]
    }.each do |label, (source, count)|
      it "finds custom store calls in linear time: #{label}" do
        path = create_file('app/models/widget.rb', source)

        unit = within_budget { described_class.new.extract_caching_file(path) }
        expect(unit.metadata[:cache_calls].size).to eq(count)
      end
    end

    it 'blanks an unclosed ERB comment tag to the end of the file in linear time' do
      path = create_file('app/views/w/f.html.erb', "#{'<%# ' * repeats}\n<% cache @w do %>")

      expect(within_budget { described_class.new.extract_caching_file(path) }).to be_nil
    end

    it 'finds the end of an ERB tag in linear time' do
      source = "cache @widget do #{'-' * repeats}%>"

      within_budget { Woods::Extractors::CacheCallArguments.read(source, 0) }
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

  # ── Incremental dispatch ─────────────────────────────────────────────

  # PathDispatcher derives the caching file rules from SCAN_PATTERNS, so an
  # incremental run reaches every view engine a full extraction scans.
  describe 'incremental dispatch' do
    def caching_dispatched?(path)
      Woods::PathDispatcher.new.file_rules_for(path).map(&:extractor_key).include?(:caching)
    end

    it 'routes every scanned view engine to the caching extractor' do
      expect(caching_dispatched?('app/views/widgets/index.html.erb')).to be(true)
      expect(caching_dispatched?('app/views/widgets/index.html.haml')).to be(true)
      expect(caching_dispatched?('app/views/ledgers/show.json.jbuilder')).to be(true)
    end

    it 'does not route slim views to the caching extractor' do
      expect(caching_dispatched?('app/views/widgets/index.html.slim')).to be(false)
    end
  end
end
