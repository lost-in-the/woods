# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/model_name_cache'
require 'woods/extractors/factory_extractor'

RSpec.describe Woods::Extractors::FactoryExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing factory directories gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers .rb files in spec/factories/' do
      create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          name { "John" }
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:factory)
    end

    it 'discovers .rb files in test/factories/' do
      create_file('test/factories/users.rb', <<~RUBY)
        factory :user do
          name { "John" }
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:factory)
    end

    it 'returns multiple units from a single file' do
      create_file('spec/factories/models.rb', <<~RUBY)
        factory :user do
        end

        factory :post do
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      expect(units.map(&:identifier)).to contain_exactly('user', 'post')
    end

    it 'collects units across multiple factory files' do
      create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
        end
      RUBY

      create_file('spec/factories/posts.rb', <<~RUBY)
        factory :post do
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end
  end

  # ── extract_factory_file ─────────────────────────────────────────────

  describe '#extract_factory_file' do
    it 'extracts a simple factory' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          name { "John" }
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:factory)
      expect(unit.identifier).to eq('user')
    end

    it 'infers model class from factory name' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin_user do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:model_class]).to eq('AdminUser')
    end

    it 'uses explicit constant class option when provided' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin_user, class: AdminUser do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:model_class]).to eq('AdminUser')
    end

    it 'uses explicit string class option when provided' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin, class: 'Admin::User' do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:model_class]).to eq('Admin::User')
    end

    it 'captures traits' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          trait :admin do
            role { "admin" }
          end

          trait :with_avatar do
            avatar { "avatar.png" }
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:traits]).to contain_exactly('admin', 'with_avatar')
    end

    it 'captures associations' do
      path = create_file('spec/factories/posts.rb', <<~RUBY)
        factory :post do
          association :author, factory: :user
          association :category
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:associations]).to contain_exactly('author', 'category')
    end

    it 'captures sequences' do
      path = create_file('spec/factories/users.rb', <<~'RUBY')
        factory :user do
          sequence(:email) { |n| "user#{n}@example.com" }
          sequence(:username) { |n| "user_#{n}" }
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:sequences]).to contain_exactly('email', 'username')
    end

    it 'captures callbacks' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          after(:create) { |u| u.confirm! }
          before(:validation) { |u| u.normalize_email }
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:callbacks]).to contain_exactly('create', 'validation')
    end

    it 'captures parent factory from parent option' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin_user, parent: :user do
          role { "admin" }
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:parent_factory]).to eq('user')
    end

    # #215 / B-102. `match_factory` required a `do` on the line, so a factory
    # that only inherits — the shape the parent: parsing exists to serve — was
    # dropped entirely.
    it 'extracts a blockless factory' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin, parent: :user
      RUBY

      units = described_class.new.extract_factory_file(path)

      expect(units.map(&:identifier)).to eq(['admin'])
      expect(units.first.metadata[:parent_factory]).to eq('user')
    end

    it 'extracts blockless and block factories from the same file' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          name { "John" }
        end

        factory :admin, parent: :user
        factory :guest, parent: :user

        factory :moderator do
          role { "mod" }
        end
      RUBY

      units = described_class.new.extract_factory_file(path)

      expect(units.map(&:identifier)).to contain_exactly('user', 'admin', 'guest', 'moderator')
    end

    # A blockless factory must not push a frame nothing will pop — if it did,
    # the next `end` would close it and every later factory would nest wrongly.
    it 'does not disturb depth tracking for factories that follow' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin, parent: :user
        factory :user do
          name { "John" }
          association :account
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      user = units.find { |unit| unit.identifier == 'user' }

      expect(user.metadata[:associations]).to eq(['account'])
    end

    it 'records a parent dependency edge for a blockless factory' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin, parent: :user
      RUBY

      units = described_class.new.extract_factory_file(path)

      expect(units.first.dependencies)
        .to include(hash_including(type: :factory, target: 'user', via: :factory_parent))
    end

    it 'captures transient attributes' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          transient do
            skip_callbacks { false }
            admin { false }
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.metadata[:transient_attributes]).to contain_exactly('skip_callbacks', 'admin')
    end

    it 'extracts nested factories as separate units' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          name { "John" }

          factory :admin_user do
            role { "admin" }
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.size).to eq(2)
      expect(units.map(&:identifier)).to contain_exactly('user', 'admin_user')
    end

    it 'works with FactoryBot.define wrapper' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        FactoryBot.define do
          factory :user do
            name { "John" }
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('user')
    end

    it 'sets file_path on each unit' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.file_path).to eq(path)
    end

    it 'sets source_code with annotation header' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.source_code).to include('# Factory: user')
      expect(units.first.source_code).to include('factory :user do')
    end

    it 'includes parent annotation in source_code when parent is set' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin_user, parent: :user do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      expect(units.first.source_code).to include('# Parent: user')
    end

    it 'includes dependencies with :via key' do
      path = create_file('spec/factories/posts.rb', <<~RUBY)
        factory :post do
          association :author
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      units.first.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'links to model via :factory_for dependency' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      model_dep = units.first.dependencies.find { |d| d[:via] == :factory_for }
      expect(model_dep).not_to be_nil
      expect(model_dep[:target]).to eq('User')
      expect(model_dep[:type]).to eq(:model)
    end

    it 'links to associated factories via :factory_association' do
      path = create_file('spec/factories/posts.rb', <<~RUBY)
        factory :post do
          association :author
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      assoc_dep = units.first.dependencies.find { |d| d[:via] == :factory_association }
      expect(assoc_dep).not_to be_nil
      expect(assoc_dep[:target]).to eq('author')
      expect(assoc_dep[:type]).to eq(:factory)
    end

    it 'links to parent factory via :factory_parent dependency' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :admin_user, parent: :user do
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      parent_dep = units.first.dependencies.find { |d| d[:via] == :factory_parent }
      expect(parent_dep).not_to be_nil
      expect(parent_dep[:target]).to eq('user')
      expect(parent_dep[:type]).to eq(:factory)
    end

    it 'does not count block keywords inside attribute strings (EXTB-2)' do
      # `title { "things to do" }` matched `block_opener?` on the string's
      # "do", inflating depth with no closing `end`. Two such attributes left
      # the factory on the stack at EOF and the unit was dropped entirely.
      path = create_file('spec/factories/checklists.rb', <<~RUBY)
        FactoryBot.define do
          factory :checklist do
            title { "things to do" }
            note { "walk for a while" }
            association :owner
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)

      expect(units.map(&:identifier)).to eq(['checklist'])
      expect(units.first.metadata[:associations]).to eq(['owner'])
    end

    it 'keeps sibling factories separate when one carries a keyword string (EXTB-2)' do
      path = create_file('spec/factories/things.rb', <<~RUBY)
        FactoryBot.define do
          factory :task_item do
            title { "things to do today" }
            association :owner
          end

          factory :note do
            association :author
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)

      expect(units.map(&:identifier)).to contain_exactly('task_item', 'note')
      expect(units.find { |u| u.identifier == 'note' }.metadata[:associations]).to eq(['author'])
    end

    it 'does not close a factory early on an assignment-form multi-line if' do
      # `record.tier = if ...` opens a construct whose line-leading `end`
      # decrements depth, but the opener rule counted `if` only in
      # line-leading position. The unbalanced `end`s brought depth back to
      # the factory's open depth one construct early, completing it while
      # its body was still being read — every attribute after that point
      # (here the association) was attributed to nothing and dropped.
      path = create_file('spec/factories/tiers.rb', <<~RUBY)
        FactoryBot.define do
          factory :alpha do
            after(:create) do |record|
              record.tier = if record.special?
                'gold'
              else
                'basic'
              end
            end
            association :owner
          end

          factory :beta do
            association :author
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)

      expect(units.map(&:identifier)).to contain_exactly('alpha', 'beta')
      expect(units.find { |u| u.identifier == 'alpha' }.metadata[:associations]).to eq(['owner'])
      expect(units.find { |u| u.identifier == 'beta' }.metadata[:associations]).to eq(['author'])
    end

    it 'returns empty array for non-rb files' do
      path = create_file('spec/factories/readme.txt', 'not a factory file')
      units = described_class.new.extract_factory_file(path)
      expect(units).to eq([])
    end

    it 'handles read errors gracefully' do
      units = described_class.new.extract_factory_file('/nonexistent/path.rb')
      expect(units).to eq([])
    end

    it 'returns empty array for file with no factories' do
      path = create_file('spec/factories/empty.rb', '# just a comment')
      units = described_class.new.extract_factory_file(path)
      expect(units).to eq([])
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      path = create_file('spec/factories/users.rb', <<~'RUBY')
        factory :user do
          trait :admin do
            role { "admin" }
          end
          association :company
          sequence(:email) { |n| "user#{n}@example.com" }
          after(:create) { |u| u.confirm! }
          transient do
            skip_callbacks { false }
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      meta = units.first.metadata

      expect(meta[:factory_name]).to eq('user')
      expect(meta[:model_class]).to eq('User')
      expect(meta[:traits]).to be_an(Array)
      expect(meta[:associations]).to be_an(Array)
      expect(meta[:sequences]).to be_an(Array)
      expect(meta[:parent_factory]).to be_nil
      expect(meta[:callbacks]).to be_an(Array)
      expect(meta[:transient_attributes]).to be_an(Array)
      expect(meta[:line_number]).to eq(1)
    end

    it 'correctly collects traits, associations, sequences, and callbacks together' do
      path = create_file('spec/factories/users.rb', <<~'RUBY')
        factory :user do
          trait :admin do
            role { "admin" }
          end
          association :company
          sequence(:email) { |n| "user#{n}@example.com" }
          after(:create) { |u| u.confirm! }
          transient do
            skip_callbacks { false }
          end
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      meta = units.first.metadata

      expect(meta[:traits]).to contain_exactly('admin')
      expect(meta[:associations]).to contain_exactly('company')
      expect(meta[:sequences]).to contain_exactly('email')
      expect(meta[:callbacks]).to contain_exactly('create')
      expect(meta[:transient_attributes]).to contain_exactly('skip_callbacks')
    end
  end

  # ── Serialization round-trip ────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('spec/factories/users.rb', <<~RUBY)
        factory :user do
          name { "John" }
        end
      RUBY

      units = described_class.new.extract_factory_file(path)
      hash = units.first.to_h

      expect(hash[:type]).to eq(:factory)
      expect(hash[:identifier]).to eq('user')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('factory')
      expect(parsed['identifier']).to eq('user')
    end
  end
end
