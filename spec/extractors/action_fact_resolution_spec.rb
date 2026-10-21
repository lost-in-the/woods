# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extractors/shared_utility_methods'
require 'woods/extractors/action_fact_resolution'

# Per-action facts for a whole class (W-7, woods#757): the action's own body
# plus the before and around filters whose declared scope names it, every
# fact attributed to the method and file it was read from.
RSpec.describe Woods::Extractors::ActionFactResolution do
  let(:app_root) { Dir.mktmpdir('woods_action_facts') }
  let(:host) do
    Class.new do
      include Woods::Extractors::SharedUtilityMethods
      include Woods::Extractors::ActionFactResolution

      public :resolve_action_facts
    end.new
  end

  after { FileUtils.rm_rf(app_root) }

  def write(relative, content)
    path = File.join(app_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def action_filter(actions)
    Object.new.tap { |o| o.instance_variable_set(:@actions, Set.new(actions)) }
  end

  def callback(kind, filter, only: nil, except: nil)
    obj = Object.new
    obj.instance_variable_set(:@if, only ? [action_filter(only)] : [])
    obj.instance_variable_set(:@unless, except ? [action_filter(except)] : [])
    obj.define_singleton_method(:kind) { kind }
    obj.define_singleton_method(:filter) { filter }
    obj
  end

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(app_root)))
    load write('app/controllers/facts_fixtures/base_controller.rb', <<~RUBY)
      module FactsFixtures
        class BaseController
          class << self
            attr_accessor :callbacks

            def _process_action_callbacks = callbacks || []
          end

          private

          def logged_in_user
            @current_user = User.find_by(id: session[:user_id])
            redirect_to login_url unless @current_user
          end
        end
      end
    RUBY
    load write('app/controllers/facts_fixtures/posts_controller.rb', <<~RUBY)
      module FactsFixtures
        class PostsController < BaseController
          def index
            @posts = Post.all
          end

          def show; end

          def create
            @post = Post.new(post_params)
            @post.save ? redirect_to(@post) : render(:new)
          end

          private

          def set_post
            @post = Post.find(params[:id])
          end
        end
      end
    RUBY
    FactsFixtures::PostsController.callbacks = [
      callback(:before, :logged_in_user, except: %w[index]),
      callback(:before, :set_post, only: %w[show]),
      callback(:after, :track_view),
      callback(:before, -> {})
    ]
  end

  def facts(actions = %w[index show create])
    host.resolve_action_facts(FactsFixtures::PostsController, actions, view_prefix: 'posts',
                                                                       permitted: { 'post_params' => 'post' })
  end

  it 'reads each action body with its file and line' do
    index = facts['index']
    expect(index).to include(file: 'app/controllers/facts_fixtures/posts_controller.rb', line: 3)
    expect(index[:assigns]).to eq([{ ivar: '@posts', line: 4, method: 'index',
                                     file: 'app/controllers/facts_fixtures/posts_controller.rb' }])
    expect(index[:renders]).to eq([{ template: 'posts/index', implicit: true, method: 'index' }])
  end

  it 'adds the assigns, params and redirects of the before filters that apply, attributed to the filter' do
    show = facts['show']
    expect(show[:assigns].map { |a| [a[:ivar], a[:method]] })
      .to eq([%w[@current_user logged_in_user], %w[@post set_post]])
    expect(show[:assigns].first[:file]).to eq('app/controllers/facts_fixtures/base_controller.rb')
    expect(show[:params]).to eq([{ key: 'id', line: 17, permitted: false, method: 'set_post',
                                   file: 'app/controllers/facts_fixtures/posts_controller.rb' }])
    expect(show[:redirects].map { |r| [r[:target], r[:method]] }).to eq([%w[login_url logged_in_user]])
  end

  it 'never adds a filter whose declared scope excludes the action, an after filter or a proc' do
    expect(facts['index'][:assigns].map { |a| a[:method] }).to eq(['index'])
    expect(facts['create'][:assigns].map { |a| a[:ivar] }).to eq(%w[@current_user @post])
  end

  it 'keeps a filter render out of the implicit-render decision for the action' do
    create = facts['create']
    expect(create[:renders].map { |r| r[:template] }).to eq(['posts/new'])
    expect(create[:params]).to eq([{ key: 'post', line: 10, permitted: true, via: 'post_params', method: 'create',
                                     file: 'app/controllers/facts_fixtures/posts_controller.rb' }])
  end

  it 'skips an action whose body is outside the application' do
    gem_file = File.join(Dir.mktmpdir('woods_gem'), 'gem_actions.rb')
    File.write(gem_file, "module FactsFixtures; class PostsController; def gem_action; @x = 1; end; end; end\n")
    load gem_file
    expect(facts(%w[gem_action])).to eq({})
  end
end
