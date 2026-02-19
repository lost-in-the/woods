# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/test_mapping_extractor'

RSpec.describe CodebaseIndex::Extractors::TestMappingExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing spec/ and test/ directories gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers *_spec.rb files in spec/' do
      create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:test_mapping)
    end

    it 'discovers *_test.rb files in test/' do
      create_file('test/models/user_test.rb', <<~RUBY)
        class UserTest < ActiveSupport::TestCase
          test "is valid" do
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:test_mapping)
    end

    it 'collects units from both spec/ and test/ directories' do
      create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
        end
      RUBY

      create_file('test/models/post_test.rb', <<~RUBY)
        class PostTest < ActiveSupport::TestCase
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end

    it 'collects units from multiple spec files' do
      create_file('spec/models/user_spec.rb', 'describe User do; end')
      create_file('spec/models/post_spec.rb', 'describe Post do; end')

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
    end
  end

  # ── extract_test_file ────────────────────────────────────────────────

  describe '#extract_test_file' do
    context 'with RSpec files' do
      it 'uses relative path as identifier' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.identifier).to eq('spec/models/user_spec.rb')
      end

      it 'sets type to :test_mapping' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.type).to eq(:test_mapping)
      end

      it 'detects subject class from constant describe' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
            it 'does something' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'detects subject class from string describe' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe 'User' do
            it 'does something' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'detects subject class from RSpec.describe form' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          RSpec.describe User do
            it 'does something' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'counts it blocks as test_count' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
            it 'is valid' do; end
            it 'has a name' do; end
            specify 'it does x' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_count]).to eq(3)
      end

      it 'sets test_framework to :rspec' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_framework]).to eq(:rspec)
      end

      it 'infers :model test_type from spec/models/ path' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:model)
      end

      it 'infers :controller test_type from spec/controllers/ path' do
        path = create_file('spec/controllers/users_controller_spec.rb',
                           'describe UsersController do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:controller)
      end

      it 'infers :request test_type from spec/requests/ path' do
        path = create_file('spec/requests/users_spec.rb', 'describe "Users API" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:request)
      end

      it 'infers :system test_type from spec/system/ path' do
        path = create_file('spec/system/login_spec.rb', 'describe "Login" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:system)
      end

      it 'defaults to :unit test_type for unrecognized paths' do
        path = create_file('spec/support/helpers_spec.rb', 'describe "Helpers" do; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:unit)
      end

      it 'detects shared_examples defined in the file' do
        path = create_file('spec/shared/user_spec.rb', <<~RUBY)
          shared_examples 'a valid user' do
            it 'is valid' do; end
          end

          shared_examples_for 'an admin' do
            it 'has admin role' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:shared_examples]).to contain_exactly('a valid user', 'an admin')
      end

      it 'detects shared_examples used in the file' do
        path = create_file('spec/models/user_spec.rb', <<~RUBY)
          describe User do
            it_behaves_like 'a valid user'
            include_examples 'an admin'
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:shared_examples_used]).to contain_exactly('a valid user', 'an admin')
      end

      it 'links to model via :test_coverage dependency for model subject' do
        path = create_file('spec/models/user_spec.rb', 'describe User do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:model)
        expect(dep[:target]).to eq('User')
        expect(dep[:via]).to eq(:test_coverage)
      end

      it 'links to controller via :test_coverage dependency for controller subject' do
        path = create_file('spec/controllers/users_controller_spec.rb',
                           'describe UsersController do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:controller)
        expect(dep[:target]).to eq('UsersController')
        expect(dep[:via]).to eq(:test_coverage)
      end

      it 'links to job via :test_coverage dependency for job subject' do
        path = create_file('spec/jobs/process_order_job_spec.rb',
                           'describe ProcessOrderJob do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:job)
        expect(dep[:target]).to eq('ProcessOrderJob')
      end

      it 'links to mailer via :test_coverage dependency for mailer subject' do
        path = create_file('spec/mailers/user_mailer_spec.rb',
                           'describe UserMailer do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:mailer)
        expect(dep[:target]).to eq('UserMailer')
      end

      it 'links to service via :test_coverage dependency for service subject' do
        path = create_file('spec/services/checkout_service_spec.rb',
                           'describe CheckoutService do; end')

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:service)
        expect(dep[:target]).to eq('CheckoutService')
      end

      it 'returns empty dependencies when subject_class is nil' do
        path = create_file('spec/support/shared_examples.rb', <<~RUBY)
          shared_examples 'a valid model' do
            it 'is valid' do; end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.dependencies).to eq([])
      end
    end

    context 'with Minitest files' do
      it 'uses relative path as identifier' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.identifier).to eq('test/models/user_test.rb')
      end

      it 'detects subject class by stripping Test suffix' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:subject_class]).to eq('User')
      end

      it 'counts test "..." blocks and def test_ methods' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
            test "is valid" do
            end

            test "has a name" do
            end

            def test_it_saves
            end
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_count]).to eq(3)
      end

      it 'sets test_framework to :minitest' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_framework]).to eq(:minitest)
      end

      it 'infers :model test_type from test/models/ path' do
        path = create_file('test/models/user_test.rb', 'class UserTest < ActiveSupport::TestCase; end')

        unit = described_class.new.extract_test_file(path)
        expect(unit.metadata[:test_type]).to eq(:model)
      end

      it 'links to model via :test_coverage dependency' do
        path = create_file('test/models/user_test.rb', <<~RUBY)
          class UserTest < ActiveSupport::TestCase
          end
        RUBY

        unit = described_class.new.extract_test_file(path)
        dep = unit.dependencies.first
        expect(dep[:type]).to eq(:model)
        expect(dep[:target]).to eq('User')
        expect(dep[:via]).to eq(:test_coverage)
      end
    end

    it 'sets source_code to the file contents' do
      path = create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do; end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(unit.source_code).to include('describe User do')
    end

    it 'sets file_path on the unit' do
      path = create_file('spec/models/user_spec.rb', 'describe User do; end')

      unit = described_class.new.extract_test_file(path)
      expect(unit.file_path).to eq(path)
    end

    it 'includes dependency with :via key' do
      path = create_file('spec/models/user_spec.rb', 'describe User do; end')

      unit = described_class.new.extract_test_file(path)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_test_file('/nonexistent/path_spec.rb')
      expect(unit).to be_nil
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes all expected keys' do
      path = create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do; end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      meta = unit.metadata

      expect(meta).to have_key(:subject_class)
      expect(meta).to have_key(:test_count)
      expect(meta).to have_key(:test_type)
      expect(meta).to have_key(:test_framework)
      expect(meta).to have_key(:shared_examples)
      expect(meta).to have_key(:shared_examples_used)
    end

    it 'returns nil subject_class when describe target is not detectable' do
      path = create_file('spec/support/misc_spec.rb', <<~RUBY)
        RSpec.configure do |config|
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      expect(unit.metadata[:subject_class]).to be_nil
    end
  end

  # ── Serialization round-trip ────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('spec/models/user_spec.rb', <<~RUBY)
        describe User do
          it 'is valid' do; end
        end
      RUBY

      unit = described_class.new.extract_test_file(path)
      hash = unit.to_h

      expect(hash[:type]).to eq(:test_mapping)
      expect(hash[:identifier]).to eq('spec/models/user_spec.rb')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('test_mapping')
      expect(parsed['identifier']).to eq('spec/models/user_spec.rb')
    end
  end
end
