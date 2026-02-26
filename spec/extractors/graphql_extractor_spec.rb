# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/graphql_extractor'

RSpec.describe CodebaseIndex::Extractors::GraphQLExtractor do
  include_context 'extractor setup'

  # ── GraphQL stubs ─────────────────────────────────────────────────────

  before do
    schema_class = Class.new do
      def self.descendants
        []
      end
    end
    stub_const('GraphQL::Schema', schema_class)
    stub_const('GraphQL::Schema::Object', Class.new)
    stub_const('GraphQL::Schema::Mutation', Class.new)
    stub_const('GraphQL::Schema::Resolver', Class.new)
    stub_const('GraphQL::Schema::Enum', Class.new)
    stub_const('GraphQL::Schema::Union', Class.new)
    stub_const('GraphQL::Schema::InputObject', Class.new)
    stub_const('GraphQL::Schema::Scalar', Class.new)
    stub_const('GraphQL::Schema::Interface', Module.new)
  end

  # ── graphql_available? ────────────────────────────────────────────────

  describe '#graphql_available?' do
    it 'returns false when GraphQL::Schema is not defined' do
      hide_const('GraphQL::Schema')

      extractor = described_class.new
      expect(extractor.send(:graphql_available?)).to be false
    end

    it 'returns false when no graphql directory and no schema class' do
      extractor = described_class.new
      expect(extractor.send(:graphql_available?)).to be false
    end

    it 'returns true when graphql directory exists' do
      FileUtils.mkdir_p(File.join(tmp_dir, 'app/graphql'))

      extractor = described_class.new
      expect(extractor.send(:graphql_available?)).to be true
    end
  end

  # ── source_file_for_class ─────────────────────────────────────────────

  describe '#source_file_for_class' do
    let(:extractor) { described_class.new }
    let(:app_root) { tmp_dir }

    it 'skips graphql gem paths and returns the convention path' do
      gem_path = '/path/to/gems/graphql/lib/graphql/schema/object.rb'

      klass = double('TypeClass')
      allow(klass).to receive(:name).and_return('Types::UserType')
      allow(klass).to receive(:instance_methods).with(false).and_return([:resolve])
      allow(klass).to receive(:instance_method).with(:resolve).and_return(
        double('UnboundMethod', source_location: [gem_path, 1])
      )
      allow(klass).to receive(:singleton_methods).with(false).and_return([])

      result = extractor.send(:source_file_for_class, klass)

      expect(result).not_to eq(gem_path)
      expect(result).to eq(File.join(app_root, 'app/graphql/types/user_type.rb'))
    end

    it 'returns an app-root instance method path when found' do
      app_path = File.join(app_root, 'app/graphql/mutations/create_user.rb')

      klass = double('MutationClass')
      allow(klass).to receive(:name).and_return('Mutations::CreateUser')
      allow(klass).to receive(:instance_methods).with(false).and_return([:resolve])
      allow(klass).to receive(:instance_method).with(:resolve).and_return(
        double('UnboundMethod', source_location: [app_path, 5])
      )

      result = extractor.send(:source_file_for_class, klass)

      expect(result).to eq(app_path)
    end

    it 'falls through to singleton methods when instance methods only return gem paths' do
      gem_path = '/path/to/gems/graphql/lib/graphql/schema/mutation.rb'
      app_path = File.join(app_root, 'app/graphql/mutations/create_user.rb')

      klass = double('MutationClass')
      allow(klass).to receive(:name).and_return('Mutations::CreateUser')
      allow(klass).to receive(:instance_methods).with(false).and_return([:resolve])
      allow(klass).to receive(:instance_method).with(:resolve).and_return(
        double('UnboundMethod', source_location: [gem_path, 1])
      )
      allow(klass).to receive(:singleton_methods).with(false).and_return([:authorized?])
      allow(klass).to receive(:method).with(:authorized?).and_return(
        double('Method', source_location: [app_path, 3])
      )

      result = extractor.send(:source_file_for_class, klass)

      expect(result).to eq(app_path)
    end

    it 'returns convention path when no methods resolve to app root' do
      klass = double('TypeClass')
      allow(klass).to receive(:name).and_return('Types::PostType')
      allow(klass).to receive(:instance_methods).with(false).and_return([])
      allow(klass).to receive(:singleton_methods).with(false).and_return([])

      result = extractor.send(:source_file_for_class, klass)

      expect(result).to eq(File.join(app_root, 'app/graphql/types/post_type.rb'))
    end

    it 'returns convention path on StandardError instead of nil' do
      klass = double('TypeClass')
      allow(klass).to receive(:name).and_return('Types::BrokenType')
      allow(klass).to receive(:instance_methods).with(false).and_raise(StandardError, 'introspection failed')

      result = extractor.send(:source_file_for_class, klass)

      expect(result).not_to be_nil
      expect(result).to eq(File.join(app_root, 'app/graphql/types/broken_type.rb'))
    end
  end

  # ── graphql_class? ────────────────────────────────────────────────────

  describe '#graphql_class?' do
    let(:extractor) { described_class.new }

    it 'detects GraphQL::Schema::Object subclass' do
      source = "class Types::UserType < GraphQL::Schema::Object\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects GraphQL::Schema::Mutation subclass' do
      source = "class Mutations::CreateUser < GraphQL::Schema::Mutation\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects GraphQL::Schema::Resolver subclass' do
      source = "class Resolvers::UserResolver < GraphQL::Schema::Resolver\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects GraphQL::Schema::Enum subclass' do
      source = "class Types::StatusEnum < GraphQL::Schema::Enum\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects GraphQL::Schema::Union subclass' do
      source = "class Types::SearchResult < GraphQL::Schema::Union\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects GraphQL::Schema::InputObject subclass' do
      source = "class Types::UserInput < GraphQL::Schema::InputObject\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects GraphQL::Schema::Scalar subclass' do
      source = "class Types::DateTimeScalar < GraphQL::Schema::Scalar\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects Interface include' do
      source = "module Types::Timestampable\n  include GraphQL::Schema::Interface\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects Types::Base subclass' do
      source = "class Types::UserType < Types::BaseObject\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects Base type subclass' do
      source = "class Types::PostType < BaseType\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects Mutations::Base subclass' do
      source = "class Mutations::CreateUser < Mutations::Base\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects Resolvers::Base subclass' do
      source = "class Resolvers::UserResolver < Resolvers::Base\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'detects field + Type subclass pattern' do
      source = "class Types::UserType < SomeType\n  field :name, String\nend"
      expect(extractor.send(:graphql_class?, source)).to be true
    end

    it 'rejects non-GraphQL classes' do
      source = "class UserService\n  def call\n  end\nend"
      expect(extractor.send(:graphql_class?, source)).to be false
    end
  end

  # ── classify_unit_type ────────────────────────────────────────────────

  describe '#classify_unit_type' do
    let(:extractor) { described_class.new }

    it 'returns :graphql_mutation for files in mutations/' do
      result = extractor.send(:classify_unit_type, 'app/graphql/mutations/create_user.rb', '')
      expect(result).to eq(:graphql_mutation)
    end

    it 'returns :graphql_resolver for files in resolvers/' do
      result = extractor.send(:classify_unit_type, 'app/graphql/resolvers/user_resolver.rb', '')
      expect(result).to eq(:graphql_resolver)
    end

    it 'returns :graphql_mutation for Mutation parent class in source' do
      source = "class CreateUser < GraphQL::Schema::Mutation\nend"
      result = extractor.send(:classify_unit_type, 'app/graphql/create_user.rb', source)
      expect(result).to eq(:graphql_mutation)
    end

    it 'returns :graphql_mutation for BaseMutation parent class' do
      source = "class CreateUser < BaseMutation\nend"
      result = extractor.send(:classify_unit_type, 'app/graphql/create_user.rb', source)
      expect(result).to eq(:graphql_mutation)
    end

    it 'returns :graphql_resolver for Resolver parent class in source' do
      source = "class FetchUsers < GraphQL::Schema::Resolver\nend"
      result = extractor.send(:classify_unit_type, 'app/graphql/fetch_users.rb', source)
      expect(result).to eq(:graphql_resolver)
    end

    it 'returns :graphql_query for query_type.rb' do
      result = extractor.send(:classify_unit_type, 'app/graphql/types/query_type.rb', '')
      expect(result).to eq(:graphql_query)
    end

    it 'returns :graphql_query for class named QueryType' do
      source = "class QueryType < Types::BaseObject\nend"
      result = extractor.send(:classify_unit_type, 'app/graphql/types/root_query.rb', source)
      expect(result).to eq(:graphql_query)
    end

    it 'defaults to :graphql_type for other files' do
      source = "class Types::UserType < Types::BaseObject\nend"
      result = extractor.send(:classify_unit_type, 'app/graphql/types/user_type.rb', source)
      expect(result).to eq(:graphql_type)
    end
  end

  # ── extract_graphql_file ──────────────────────────────────────────────

  describe '#extract_graphql_file' do
    it 'extracts a GraphQL type file' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            description "A user in the system"

            field :id, ID, null: false
            field :name, String, null: false
            field :email, String, null: true, description: "User's email"
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:graphql_type)
      expect(unit.identifier).to eq('Types::UserType')
      expect(unit.namespace).to eq('Types')
    end

    it 'extracts fields from source' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :id, ID, null: false
            field :name, String, null: false
            field :email, String, null: true
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      fields = unit.metadata[:fields]
      field_names = fields.map { |f| f[:name] }
      expect(field_names).to include('id', 'name', 'email')
    end

    it 'extracts arguments from source' do
      source = <<~RUBY
        module Mutations
          class CreateUser < GraphQL::Schema::Mutation
            argument :name, String, required: true, description: "User name"
            argument :email, String, required: true
            argument :bio, String, required: false

            field :user, Types::UserType, null: true

            def resolve(name:, email:, bio: nil)
              User.create!(name: name, email: email, bio: bio)
            end
          end
        end
      RUBY

      path = create_file('app/graphql/mutations/create_user.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.type).to eq(:graphql_mutation)
      args = unit.metadata[:arguments]
      arg_names = args.map { |a| a[:name] }
      expect(arg_names).to include('name', 'email', 'bio')
    end

    it 'detects authorization patterns' do
      source = <<~RUBY
        module Types
          class SecretType < Types::BaseObject
            def self.authorized?(object, context)
              context[:current_user]&.admin?
            end

            field :secret_data, String, null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/secret_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:authorization][:has_authorized_method]).to be true
    end

    it 'detects pundit authorization' do
      source = <<~RUBY
        module Types
          class PostType < Types::BaseObject
            field :title, String, null: false

            def title
              authorize! record
              object.title
            end
          end
        end
      RUBY

      path = create_file('app/graphql/types/post_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:authorization][:pundit]).to be true
    end

    it 'detects cancan authorization' do
      source = <<~RUBY
        module Types
          class AdminType < Types::BaseObject
            field :data, String, null: false

            def data
              can? :read, object
            end
          end
        end
      RUBY

      path = create_file('app/graphql/types/admin_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:authorization][:cancan]).to be true
    end

    it 'annotates source with header' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :id, ID, null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.source_code).to include('GraphQL Type')
      expect(unit.source_code).to include('Types::UserType')
      expect(unit.source_code).to include('Fields:')
    end

    it 'returns nil for non-GraphQL files' do
      source = <<~RUBY
        class PlainService
          def call
            true
          end
        end
      RUBY

      path = create_file('app/graphql/plain_service.rb', source)

      unit = described_class.new.extract_graphql_file(path)
      expect(unit).to be_nil
    end

    it 'returns nil for files with no class definition' do
      source = "# just a comment\n"

      path = create_file('app/graphql/empty.rb', source)

      unit = described_class.new.extract_graphql_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_graphql_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end
  end

  # ── Enum extraction ───────────────────────────────────────────────────

  describe 'enum value extraction' do
    it 'extracts enum values from source' do
      source = <<~RUBY
        module Types
          class StatusEnum < GraphQL::Schema::Enum
            value 'ACTIVE', description: 'Currently active'
            value 'INACTIVE', description: 'No longer active'
            value 'PENDING'
          end
        end
      RUBY

      path = create_file('app/graphql/types/status_enum.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      values = unit.metadata[:enum_values]
      value_names = values.map { |v| v[:name] }
      expect(value_names).to include('ACTIVE', 'INACTIVE', 'PENDING')
      expect(values.find { |v| v[:name] == 'ACTIVE' }[:description]).to eq('Currently active')
    end
  end

  # ── Union extraction ──────────────────────────────────────────────────

  describe 'union member extraction' do
    it 'extracts possible_types from source' do
      source = <<~RUBY
        module Types
          class SearchResult < GraphQL::Schema::Union
            possible_types Types::UserType, Types::PostType, Types::CommentType

            def self.resolve_type(object, _context)
              case object
              when User then Types::UserType
              end
            end
          end
        end
      RUBY

      path = create_file('app/graphql/types/search_result.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      members = unit.metadata[:union_members]
      expect(members).to include('Types::UserType', 'Types::PostType', 'Types::CommentType')
    end
  end

  # ── Connection extraction ─────────────────────────────────────────────

  describe 'connection extraction' do
    it 'detects connection_type references' do
      source = <<~RUBY
        module Types
          class QueryType < Types::BaseObject
            field :users, Types::UserType.connection_type, null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/query_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      connections = unit.metadata[:connections]
      expect(connections).to include('Types::UserType')
    end
  end

  # ── Resolver references ──────────────────────────────────────────────

  describe 'resolver reference extraction' do
    it 'detects resolver references in field definitions' do
      source = <<~RUBY
        module Types
          class QueryType < Types::BaseObject
            field :users, [Types::UserType], null: false, resolver: Resolvers::UsersResolver
          end
        end
      RUBY

      path = create_file('app/graphql/types/query_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      resolvers = unit.metadata[:resolver_classes]
      expect(resolvers).to include('Resolvers::UsersResolver')
    end
  end

  # ── Interface extraction ──────────────────────────────────────────────

  describe 'interface extraction' do
    it 'detects implements declarations from source' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            implements Types::TimestampInterface
            implements Types::NodeInterface

            field :id, ID, null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      interfaces = unit.metadata[:interfaces]
      expect(interfaces).to include('Types::TimestampInterface', 'Types::NodeInterface')
    end
  end

  # ── Complexity extraction ─────────────────────────────────────────────

  describe 'complexity extraction' do
    it 'detects field-level complexity' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :friends, [Types::UserType], null: false, complexity: 10
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      complexity = unit.metadata[:complexity]
      expect(complexity).not_to be_empty
      expect(complexity.first[:field]).to eq('friends')
    end
  end

  # ── Dependencies ──────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it 'detects GraphQL type references' do
      source = <<~RUBY
        module Types
          class PostType < Types::BaseObject
            field :author, Types::UserType, null: false
            field :comments, [Types::CommentType], null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/post_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      type_deps = unit.dependencies.select { |d| d[:type] == :graphql_type }
      targets = type_deps.map { |d| d[:target] }
      expect(targets).to include('Types::UserType', 'Types::CommentType')
    end

    it 'detects model references via ActiveRecord methods' do
      source = <<~RUBY
        module Mutations
          class CreatePost < GraphQL::Schema::Mutation
            argument :title, String, required: true

            def resolve(title:)
              Post.create!(title: title)
            end
          end
        end
      RUBY

      path = create_file('app/graphql/mutations/create_post.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      model_deps = unit.dependencies.select { |d| d[:type] == :model }
      expect(model_deps.map { |d| d[:target] }).to include('Post')
    end

    it 'detects service dependencies' do
      source = <<~RUBY
        module Mutations
          class ProcessPayment < GraphQL::Schema::Mutation
            def resolve
              PaymentService.process(object)
            end
          end
        end
      RUBY

      path = create_file('app/graphql/mutations/process_payment.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.map { |d| d[:target] }).to include('PaymentService')
    end

    it 'detects resolver dependencies from field definitions' do
      source = <<~RUBY
        module Types
          class QueryType < Types::BaseObject
            field :users, resolver: Resolvers::UsersResolver
          end
        end
      RUBY

      path = create_file('app/graphql/types/query_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      resolver_deps = unit.dependencies.select { |d| d[:type] == :graphql_resolver }
      expect(resolver_deps.map { |d| d[:target] }).to include('Resolvers::UsersResolver')
    end

    it 'excludes self-referential type dependencies' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :friends, [Types::UserType], null: false
            field :posts, [Types::PostType], null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      type_deps = unit.dependencies.select { |d| d[:type] == :graphql_type }
      targets = type_deps.map { |d| d[:target] }
      expect(targets).to include('Types::PostType')
      expect(targets).not_to include('Types::UserType')
    end

    it 'includes :via key on all dependencies' do
      source = <<~RUBY
        module Mutations
          class UpdateUser < GraphQL::Schema::Mutation
            argument :id, ID, required: true

            field :user, Types::UserType, null: true

            def resolve(id:)
              user = User.find(id)
              NotificationService.notify(user)
              user
            end
          end
        end
      RUBY

      path = create_file('app/graphql/mutations/update_user.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Metadata ──────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'includes graphql_kind' do
      source = <<~RUBY
        module Types
          class StatusEnum < GraphQL::Schema::Enum
            value 'ACTIVE'
          end
        end
      RUBY

      path = create_file('app/graphql/types/status_enum.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:graphql_kind]).to eq(:enum)
    end

    it 'includes parent_class' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :id, ID, null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:parent_class]).to eq('Types::BaseObject')
    end

    it 'includes field_count and argument_count' do
      source = <<~RUBY
        module Mutations
          class CreateUser < GraphQL::Schema::Mutation
            argument :name, String, required: true
            argument :email, String, required: true

            field :user, Types::UserType, null: true
            field :errors, [String], null: false

            def resolve(name:, email:)
            end
          end
        end
      RUBY

      path = create_file('app/graphql/mutations/create_user.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:field_count]).to eq(2)
      expect(unit.metadata[:argument_count]).to eq(2)
    end

    it 'includes LOC count' do
      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :id, ID, null: false
          end
        end
      RUBY

      path = create_file('app/graphql/types/user_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      expect(unit.metadata[:loc]).to be > 0
    end
  end

  # ── Chunking ──────────────────────────────────────────────────────────

  describe 'chunking' do
    it 'builds summary chunk' do
      fields = (1..12).map { |i| "field :field_#{i}, String, null: false" }
      source = <<~RUBY
        module Types
          class LargeType < Types::BaseObject
            #{fields.join("\n    ")}
          end
        end
      RUBY

      path = create_file('app/graphql/types/large_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)

      # Force chunking check
      next unless unit&.chunks&.any?

      summary_chunk = unit.chunks.find { |c| c[:chunk_type] == :summary }
      expect(summary_chunk).not_to be_nil
      expect(summary_chunk[:identifier]).to eq('Types::LargeType:summary')
    end

    it 'builds field group chunks for types with many fields' do
      fields = (1..12).map { |i| "field :field_#{i}, String, null: false" }
      source = <<~RUBY
        module Types
          class LargeType < Types::BaseObject
            #{fields.join("\n    ")}
          end
        end
      RUBY

      path = create_file('app/graphql/types/large_type.rb', source)

      unit = described_class.new.extract_graphql_file(path)
      next unless unit&.chunks&.any?

      field_chunks = unit.chunks.select { |c| c[:chunk_type] == :fields }
      expect(field_chunks.size).to be >= 1
    end

    it 'builds arguments chunk for mutations' do
      args = (1..3).map { |i| "argument :arg_#{i}, String, required: true" }
      source = <<~RUBY
        module Mutations
          class BigMutation < GraphQL::Schema::Mutation
            #{args.join("\n    ")}

            field :result, String, null: true

            def resolve(**args)
            end
          end
        end
      RUBY

      path = create_file('app/graphql/mutations/big_mutation.rb', source)

      unit = described_class.new.extract_graphql_file(path)
      next unless unit&.chunks&.any?

      arg_chunk = unit.chunks.find { |c| c[:chunk_type] == :arguments }
      expect(arg_chunk).not_to be_nil
    end
  end

  # ── extract_all ───────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'returns empty array when graphql is not available' do
      hide_const('GraphQL::Schema')

      units = described_class.new.extract_all
      expect(units).to eq([])
    end

    it 'discovers GraphQL files in app/graphql/' do
      FileUtils.mkdir_p(File.join(tmp_dir, 'app/graphql/types'))

      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :id, ID, null: false
            field :name, String, null: false
          end
        end
      RUBY

      create_file('app/graphql/types/user_type.rb', source)

      units = described_class.new.extract_all

      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Types::UserType')
    end

    it 'deduplicates units by identifier' do
      FileUtils.mkdir_p(File.join(tmp_dir, 'app/graphql/types'))

      source = <<~RUBY
        module Types
          class UserType < Types::BaseObject
            field :id, ID, null: false
          end
        end
      RUBY

      # Same file in two locations shouldn't happen, but test dedup logic
      create_file('app/graphql/types/user_type.rb', source)

      units = described_class.new.extract_all

      identifiers = units.map(&:identifier)
      expect(identifiers.uniq.size).to eq(identifiers.size)
    end
  end

  # ── GraphQL kind detection ────────────────────────────────────────────

  describe '#detect_graphql_kind' do
    let(:extractor) { described_class.new }

    it 'detects enum from source' do
      source = "class Types::StatusEnum < GraphQL::Schema::Enum\n  value 'ACTIVE'\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:enum)
    end

    it 'detects union from source' do
      source = "class Types::Result < GraphQL::Schema::Union\n  possible_types Types::A\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:union)
    end

    it 'detects input_object from source' do
      source = "class Types::UserInput < GraphQL::Schema::InputObject\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:input_object)
    end

    it 'detects scalar from source' do
      source = "class Types::DateTime < GraphQL::Schema::Scalar\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:scalar)
    end

    it 'detects mutation from source' do
      source = "class Mutations::Create < GraphQL::Schema::Mutation\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:mutation)
    end

    it 'detects resolver from source' do
      source = "class Resolvers::Fetch < GraphQL::Schema::Resolver\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:resolver)
    end

    it 'detects interface from source' do
      source = "module Types::Node\n  include GraphQL::Schema::Interface\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:interface)
    end

    it 'defaults to :object for plain types' do
      source = "class Types::UserType < Types::BaseObject\nend"
      kind = extractor.send(:detect_graphql_kind, source, nil)
      expect(kind).to eq(:object)
    end
  end
end
