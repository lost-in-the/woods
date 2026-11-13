# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/filename_utils'
require 'woods/method_table'
require 'woods/file_lines'
require 'woods/mcp/server'

# `lookup` of `Owner#member` or `Owner.member` that is not itself a published
# unit answers with the owner's unit narrowed to that method: its span, its
# source and a statement that it is a member of the owner, not a unit. An
# identifier that is a published unit keeps resolving to that unit.
RSpec.describe 'MCP lookup of a unit member' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-lookup-member') }

  def concern_block(name, code)
    indented = code.lines.map { |line| "  # #{line.rstrip}" }.join("\n")
    <<~CONCERN
      # ┌─────────────────────────────────────────────────────────────────────┐
      # │ Included from: #{name.ljust(54)}│
      # └─────────────────────────────────────────────────────────────────────┘
      #{indented}
      # ─────────────────────────── End #{name} ───────────────────────────
    CONCERN
  end

  # A concern's own singleton methods (`def self.x`, `class << self`,
  # `module_function`) are not methods of the class that includes it; only
  # its `class_methods do` definitions are.
  let(:publishable_code) do
    <<~RUBY
      module Publishable
        def archive
          update!(archived: true)
        end

        def self.format(value)
          value.to_s
        end

        def self.slugify(value)
          value.to_s.parameterize
        end

        class << self
          def helper; end
        end

        module_function

        def tool; end
      end
    RUBY
  end

  let(:formatting_code) do
    <<~RUBY
      module Formatting
        extend ActiveSupport::Concern

        class_methods do
          def format(value)
            value.to_s.upcase
          end

          private def hidden; end
        end
      end
    RUBY
  end

  let(:money_columns_code) do
    <<~RUBY
      module Canopy
        module MoneyColumns
          class_methods do
            def money_column(name)
              name
            end
          end
        end
      end
    RUBY
  end

  let(:post_source) do
    blocks = concern_block('Publishable', publishable_code) + concern_block('Formatting', formatting_code) +
             concern_block('Canopy::MoneyColumns', money_columns_code)
    <<~RUBY + blocks
      class Post < ApplicationRecord
        def self.recent
          order(:id)
        end

        def publish!
          update!(published: true)
        end

        def published?
          published
        end

        def title=(value)
          super(value.strip)
        end
      end
    RUBY
  end

  let(:controller_source) do
    <<~RUBY
      class PostsController < ApplicationController
        def index
          @posts = Post.all
        end

        def create
          @post = Post.create!(params[:post])
        end
      end
    RUBY
  end

  let(:admin_source) do
    <<~RUBY
      module Admin
        class PostsController < ApplicationController
          def create
            head :created
          end
        end
      end
    RUBY
  end

  # The method table as extraction publishes it. Post's file is its leading
  # 17 lines verbatim; the controller's file lines are shifted to prove the
  # published table is what lookup reads.
  def published_methods(source, identity_lines: nil, shift: 0)
    locator = Woods::FileLines::Locator.new(source, nil, identity_lines: identity_lines)
    Woods::MethodTable.call(source).map do |entry|
      entry = locator.annotate(entry)
      if shift.zero?
        entry
      else
        entry.merge('file_line' => entry['line'] + shift,
                    'file_end_line' => entry['end_line'] + shift)
      end
    end
  end

  let(:util_source) do
    <<~RUBY
      module Canopy
        module Util
          module_function

          def tool; end
        end
      end
    RUBY
  end

  # [directory, type, identifier, file_path, source, metadata]
  let(:units) do
    [
      ['models', 'model', 'Post', 'app/models/post.rb', post_source,
       { 'methods' => published_methods(post_source, identity_lines: 17) }],
      ['concerns', 'concern', 'Publishable', 'app/models/concerns/publishable.rb', 'module Publishable; end', {}],
      ['controllers', 'controller', 'PostsController', 'app/controllers/posts_controller.rb', controller_source,
       { 'methods' => published_methods(controller_source, shift: 10) }],
      # An index that predates the published method table.
      ['controllers', 'controller', 'Admin::PostsController', 'app/controllers/admin/posts_controller.rb',
       admin_source, {}],
      # A module whose own body uses module_function.
      ['libs', 'lib', 'Canopy::Util', 'lib/canopy/util.rb', util_source,
       { 'methods' => published_methods(util_source, identity_lines: 7) }],
      # A published unit whose identifier has the member form.
      ['routes', 'route', 'PostsController#index', 'config/routes.rb', 'get "/posts", to: "posts#index"', {}]
    ]
  end

  before do
    units.group_by(&:first).each do |directory, rows|
      path = File.join(index_dir, directory)
      FileUtils.mkdir_p(path)
      entries = rows.map do |(_, type, identifier, file_path, source, metadata)|
        unit = { 'type' => type, 'identifier' => identifier, 'file_path' => file_path,
                 'source_code' => source, 'metadata' => metadata }
        File.write(File.join(path, collision_safe_filename(identifier)), JSON.generate(unit))
        { 'identifier' => identifier, 'type' => type, 'file_path' => file_path }
      end
      File.write(File.join(path, '_index.json'), JSON.generate(entries.sort_by { |e| e['identifier'] }))
    end
    File.write(File.join(index_dir, 'manifest.json'), JSON.generate('counts' => units.map(&:first).tally))
  end

  after { FileUtils.remove_entry(index_dir) }

  def build(format = :markdown)
    Woods::MCP::Server.build(index_dir: index_dir, response_format: format, warmup: false)
  end

  def call(server, **arguments)
    server.instance_variable_get(:@tools).fetch('lookup').call(**arguments, server_context: {})
  end

  def text(response)
    response.content.first[:text]
  end

  def member(identifier, format: :json, **arguments)
    response = call(build(format), identifier: identifier, **arguments)
    expect(response.error?).to be(false), text(response)
    format == :json ? JSON.parse(text(response)) : text(response)
  end

  describe 'a member the owner defines' do
    it 'answers an instance method with its span, source and owner' do
      data = member('PostsController#create')

      expect(data).to include(
        'identifier' => 'PostsController#create',
        'member_of' => { 'identifier' => 'PostsController', 'type' => 'controller',
                         'file_path' => 'app/controllers/posts_controller.rb' },
        'source_code' => "  def create\n    @post = Post.create!(params[:post])\n  end\n"
      )
      expect(data['member']).to include('name' => 'create', 'kind' => 'instance', 'visibility' => 'public',
                                        'line' => 6, 'end_line' => 8, 'file_line' => 16, 'file_end_line' => 18)
      expect(data['statement']).to eq('PostsController#create is a public instance method of controller unit ' \
                                      'PostsController, not a unit of its own. ' \
                                      'Look up PostsController for the whole unit.')
    end

    it 'answers a class method named with a dot' do
      data = member('Post.recent')

      expect(data['member']).to include('name' => 'recent', 'kind' => 'singleton', 'line' => 2, 'end_line' => 4,
                                        'file_line' => 2, 'file_end_line' => 4)
      expect(data['source_code']).to eq("  def self.recent\n    order(:id)\n  end\n")
      expect(data['statement']).to start_with('Post.recent is a public class method of model unit Post')
    end

    it 'does not answer an instance method named as a class method, or the reverse' do
      %w[Post.publish! Post#recent].each do |identifier|
        response = call(build, identifier: identifier)

        expect(response.error?).to be(true)
        expect(response.meta).to include(error_code: :not_found)
      end
    end

    {
      'Post#publish!' => [6, 8],
      'Post#published?' => [10, 12],
      'Post#title=' => [14, 16]
    }.each do |identifier, (first, last)|
      it "answers #{identifier}" do
        expect(member(identifier)['member']).to include('line' => first, 'end_line' => last)
      end
    end

    it 'answers a namespaced owner, locating the method in the source when no table is published' do
      data = member('Admin::PostsController#create')

      expect(data['member_of']).to include('identifier' => 'Admin::PostsController', 'type' => 'controller')
      expect(data['member']).to include('owner' => 'Admin::PostsController', 'line' => 3, 'end_line' => 5)
      expect(data['source_code']).to eq("    def create\n      head :created\n    end\n")
    end

    it 'names the concern file of a method inlined from a concern' do
      data = member('Post#archive')

      expect(data['member']).to include('file_unit' => 'Publishable', 'file_line' => 2, 'file_end_line' => 4)
      expect(data['defined_in']).to eq('identifier' => 'Publishable',
                                       'file_path' => 'app/models/concerns/publishable.rb')
      expect(data['source_code']).to eq("  def archive\n    update!(archived: true)\n  end\n")
    end

    it 'answers a class method a concern declares in class_methods' do
      data = member('Post.format')

      expect(data['member']).to include('name' => 'format', 'kind' => 'singleton', 'file_unit' => 'Formatting',
                                        'file_line' => 5, 'file_end_line' => 7)
      expect(data['source_code']).to eq("    def format(value)\n      value.to_s.upcase\n    end\n")
      expect(data['statement']).to start_with('Post.format is a public class method of model unit Post')
    end

    it 'never lists a concern-local singleton beside the class_methods definition' do
      expect(member('Post.format')).not_to have_key('other_definitions')
    end

    it 'answers class_methods of a namespaced concern, and their visibility' do
      expect(member('Post.money_column')['member']).to include('file_unit' => 'Canopy::MoneyColumns',
                                                               'file_line' => 4, 'file_end_line' => 6)
      expect(member('Post.hidden')['member']).to include('visibility' => 'private', 'file_unit' => 'Formatting')
    end

    {
      'Post.slugify' => 'def self. in a concern',
      'Post.helper' => 'class << self in a concern',
      'Post.tool' => 'a module_function of a concern',
      'Post#format' => 'a class_methods method, as an instance method'
    }.each do |identifier, form|
      it "does not answer #{form} (#{identifier}) as a member of the including unit" do
        response = call(build, identifier: identifier)

        expect(response.error?).to be(true)
        expect(response.meta).to include(error_code: :not_found, member_of: { identifier: 'Post', type: 'model' })
      end
    end

    it 'leaves the source out with include_source: false' do
      expect(member('PostsController#create', include_source: false)).not_to have_key('source_code')
    end

    %i[markdown plain claude].each do |format|
      it "states the member and its lines in the #{format} format" do
        answer = member('PostsController#create', format: format)

        expect(answer).to include('PostsController#create is a public instance method of controller unit ' \
                                  'PostsController, not a unit of its own.')
        expect(answer).to include('app/controllers/posts_controller.rb').and include('16-18')
        expect(answer).to include('@post = Post.create!(params[:post])')
        expect(answer).not_to include('@posts = Post.all')
      end
    end

    it 'carries the owner in the response meta' do
      response = call(build, identifier: 'PostsController#create')

      expect(response.meta).to include(member_of: { identifier: 'PostsController', type: 'controller' })
    end
  end

  describe 'module_function' do
    # `module_function` makes a public singleton copy on the module and leaves
    # the instance method private; an including class gets only the private
    # instance method.
    it "answers a concern's module_function as the includer's private instance method" do
      data = member('Post#tool')

      expect(data['member']).to include('name' => 'tool', 'kind' => 'instance', 'visibility' => 'private',
                                        'file_unit' => 'Publishable')
      expect(data['defined_in']).to include('identifier' => 'Publishable')
      expect(data['statement']).to start_with('Post#tool is a private instance method of model unit Post,')
    end

    it 'does not change the published method table' do
      call(build, identifier: 'Post#tool')
      unit = JSON.parse(File.read(File.join(index_dir, 'models', collision_safe_filename('Post')), encoding: 'UTF-8'))

      expect(unit['metadata']['methods'].find { |entry| entry['name'] == 'tool' })
        .to include('kind' => 'module_function', 'visibility' => 'public')
    end

    it "answers a module's own module_function with a dot as a public module function" do
      data = member('Canopy::Util.tool')

      expect(data['member']).to include('kind' => 'module_function', 'visibility' => 'public')
      expect(data['statement']).to start_with('Canopy::Util.tool is a public module function of lib unit')
    end

    it "answers a module's own module_function with # as its private instance method" do
      data = member('Canopy::Util#tool')

      expect(data['member']).to include('kind' => 'instance', 'visibility' => 'private')
      expect(data['statement']).to start_with('Canopy::Util#tool is a private instance method of lib unit')
    end
  end

  describe 'an owner without the member' do
    it 'says the owner exists and the member is not in its published source' do
      response = call(build, identifier: 'Post#destroy_all')

      expect(response.error?).to be(true)
      expect(text(response)).to eq('Unit not found: Post#destroy_all. Post (model) is a published unit, but ' \
                                   'destroy_all (instance method) was not found in its published source. ' \
                                   'Did you mean: Post (model)?')
      expect(response.meta).to include(error_code: :not_found, member_of: { identifier: 'Post', type: 'model' },
                                       suggestions: [{ identifier: 'Post', type: 'model' }])
    end
  end

  describe 'an owner that is not published' do
    it 'answers not found as before' do
      response = call(build, identifier: 'Widget#create')

      expect(response.error?).to be(true)
      expect(text(response)).to eq('Unit not found: Widget#create')
      expect(response.meta).not_to have_key(:member_of)
    end
  end

  describe 'an identifier that is a published unit' do
    it 'returns that unit, not a member' do
      data = member('PostsController#index')

      expect(data).to include('type' => 'route', 'identifier' => 'PostsController#index')
      expect(data).not_to have_key('member_of')
    end
  end

  describe 'with type' do
    it 'narrows the owner of that type' do
      data = member('PostsController#index', type: 'controller')

      expect(data['member_of']).to include('identifier' => 'PostsController', 'type' => 'controller')
      expect(data['source_code']).to include('@posts = Post.all')
    end

    it 'keeps the exact unit of that type' do
      expect(member('PostsController#index', type: 'route')).to include('type' => 'route')
    end

    it 'answers not found when the owner is not of that type' do
      response = call(build, identifier: 'PostsController#create', type: 'model')

      expect(text(response)).to eq('Unit not found: PostsController#create (type model). ' \
                                   'Did you mean: PostsController (controller), Admin::PostsController (controller)?')
      expect(response.meta).not_to have_key(:member_of)
    end
  end

  it 'refuses arguments that do not apply to one member' do
    response = call(build, identifier: 'PostsController#create', evidence: 'compact')

    expect(response.error?).to be(true)
    expect(response.meta).to include(error_code: :unsupported_argument, tool: 'lookup')
    expect(text(response)).to include('member of PostsController')
  end
end
