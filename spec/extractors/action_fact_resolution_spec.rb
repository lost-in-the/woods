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

  it 'reads an alias target at its runtime source site while keeping the dispatched action template' do
    load write('app/controllers/facts_fixtures/aliased_controller.rb', <<~RUBY)
      module FactsFixtures
        class AliasedController < BaseController
          def show
            @obsolete = true
            render :obsolete
          end

          def preview
            @preview = params[:id]
          end

          alias_method :show, :preview
        end
      end
    RUBY
    result = host.resolve_action_facts(FactsFixtures::AliasedController, %w[show], view_prefix: 'aliased')
    show = result.fetch('show')

    expect(show[:line]).to eq(8)
    expect(show[:assigns]).to eq(
      [{ ivar: '@preview', line: 9, method: 'show', file: 'app/controllers/facts_fixtures/aliased_controller.rb' }]
    )
    expect(show[:renders]).to eq([{ template: 'aliased/show', implicit: true, method: 'show' }])
  end

  it 'does not borrow a same-named definition for a generated action or attribute reader' do
    load write('app/controllers/facts_fixtures/generated_controller.rb', <<~RUBY)
      module FactsFixtures
        class GeneratedController < BaseController
          attr_reader :show
          define_method(:create) { @generated = true }
        end

        class UnrelatedController < BaseController
          def show; @unrelated_show = true; end
          def create; @unrelated_create = true; end
        end
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::GeneratedController, %w[show create], view_prefix: 'generated')

    expect(result).to eq({})
  end

  it 'builds one definition index per file across actions and shared filters' do
    expect(Woods::Extractors::ActionFacts).to receive(:definitions).twice.and_call_original

    2.times { facts }
  end

  it 'leaves generated methods unresolved when an unrelated definition shares their source line' do
    load write('app/controllers/facts_fixtures/same_line_controller.rb',
               'module FactsFixtures; class SameLineController < BaseController; ' \
               'attr_reader :show; define_method(:create) { @created = true }; end; ' \
               'class OtherSameLineController < BaseController; ' \
               'def show; @wrong_show = true; end; def create; @wrong_create = true; end; end; end')

    result = host.resolve_action_facts(FactsFixtures::SameLineController, %w[show create], view_prefix: 'same_line')

    expect(result).to eq({})
  end

  it 'omits a compact definition and alias sharing an accessor source line' do
    load write('app/controllers/facts_fixtures/same_line_alias_controller.rb',
               'module FactsFixtures; class SameLineAliasController < BaseController; ' \
               'attr_reader :show; def preview; @preview = true; end; alias_method :show, :preview; end; end')

    result = host.resolve_action_facts(FactsFixtures::SameLineAliasController, %w[show], view_prefix: 'same_line_alias')

    expect(result).to eq({})
  end

  it 'keeps a definition and alias on separate lines from an accessor' do
    load write('app/controllers/facts_fixtures/separate_line_alias_controller.rb', <<~RUBY)
      class FactsFixtures::SeparateLineAliasController < FactsFixtures::BaseController
        attr_reader :show
        def preview; @preview = true; end
        alias_method :show, :preview
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::SeparateLineAliasController, %w[show],
                                       view_prefix: 'separate_line')

    expect(result.fetch('show')[:assigns]).to include(hash_including(ivar: '@preview', method: 'show'))
    expect(result.fetch('show')[:renders])
      .to eq([{ template: 'separate_line/show', implicit: true, method: 'show' }])
  end

  it 'leaves dynamic generated methods unresolved beside unrelated definitions on the same line' do
    load write('app/controllers/facts_fixtures/dynamic_same_line_controller.rb',
               'module FactsFixtures; class DynamicSameLineController < BaseController; ' \
               'reader = :show; creator = :create; attr_reader reader; ' \
               'define_method(creator) { @created = true }; end; ' \
               'class DynamicOtherController < BaseController; ' \
               'def show; @wrong_show = true; end; def create; @wrong_create = true; end; end; end')

    result = host.resolve_action_facts(FactsFixtures::DynamicSameLineController, %w[show create],
                                       view_prefix: 'dynamic_same_line')

    expect(result).to eq({})
  end

  it 'does not borrow definitions at a Proc source site when another file installs the method' do
    load write('app/controllers/facts_fixtures/proc_body.rb',
               'module FactsFixtures; BODY = proc { @generated = true }; ' \
               'class OtherProcController; def show; @wrong = true; end; end; end')
    load write('app/controllers/facts_fixtures/proc_body_controller.rb', <<~RUBY)
      class FactsFixtures::ProcBodyController < FactsFixtures::BaseController
        define_method(:show, FactsFixtures::BODY)
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::ProcBodyController, %w[show], view_prefix: 'proc_body')

    expect(result).to eq({})
  end

  it 'does not borrow definitions at the source site of a multiline inline lambda argument' do
    load write('app/controllers/facts_fixtures/lambda_body_controller.rb', <<~RUBY)
      class FactsFixtures::LambdaBodyController < FactsFixtures::BaseController
        define_method(:show,
          ->(
            value
          ) { @generated = value }); class Other; def show; @wrong = true; end; end
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::LambdaBodyController, %w[show], view_prefix: 'lambda_body')

    expect(result).to eq({})
  end

  it 'keeps a known original definition when define_method copies an UnboundMethod body' do
    load write('app/controllers/facts_fixtures/copied_method_controller.rb', <<~RUBY)
      class FactsFixtures::CopiedMethodController < FactsFixtures::BaseController
        def preview; @preview = true; end
        define_method(:show, instance_method(:preview))
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::CopiedMethodController, %w[show], view_prefix: 'copied_method')

    expect(result.fetch('show')[:assigns]).to include(hash_including(ivar: '@preview', method: 'show'))
    expect(result.fetch('show')[:renders])
      .to eq([{ template: 'copied_method/show', implicit: true, method: 'show' }])
  end

  it 'does not borrow definitions at the source site of an instance Method converted to Proc' do
    load write('app/controllers/facts_fixtures/method_proc_body.rb',
               'module FactsFixtures; class OriginalMethod; def preview; @original = true; end; end; ' \
               'class OtherMethod; def show; @wrong = true; end; end; ' \
               'METHOD_BODY = OriginalMethod.instance_method(:preview).bind(OriginalMethod.allocate).to_proc; end')
    load write('app/controllers/facts_fixtures/method_proc_controller.rb', <<~RUBY)
      class FactsFixtures::MethodProcController < FactsFixtures::BaseController
        define_method(:show, FactsFixtures::METHOD_BODY)
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::MethodProcController, %w[show], view_prefix: 'method_proc')

    expect(result).to eq({})
  end

  it 'does not borrow definitions at the source site of a singleton Method converted to Proc' do
    load write('app/controllers/facts_fixtures/singleton_proc_body.rb',
               'module FactsFixtures; class OriginalSingleton; def self.preview; @original = true; end; end; ' \
               'class OtherSingleton; def show; @wrong = true; end; end; ' \
               'SINGLETON_BODY = OriginalSingleton.method(:preview).to_proc; end')
    load write('app/controllers/facts_fixtures/singleton_proc_controller.rb', <<~RUBY)
      class FactsFixtures::SingletonProcController < FactsFixtures::BaseController
        define_method(:show, FactsFixtures::SINGLETON_BODY)
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::SingletonProcController, %w[show], view_prefix: 'singleton_proc')

    expect(result).to eq({})
  end

  it 'does not borrow definitions when an attribute reader Method is renamed through a Proc' do
    load write('app/controllers/facts_fixtures/attribute_proc_body.rb',
               'module FactsFixtures; class OriginalAttribute; attr_reader :preview; end; ' \
               'class OtherAttribute; def show; @wrong = true; end; end; ' \
               'ATTRIBUTE_BODY = OriginalAttribute.instance_method(:preview)' \
               '.bind(OriginalAttribute.allocate).to_proc; end')
    load write('app/controllers/facts_fixtures/attribute_proc_controller.rb', <<~RUBY)
      class FactsFixtures::AttributeProcController < FactsFixtures::BaseController
        define_method(:show, FactsFixtures::ATTRIBUTE_BODY)
      end
    RUBY

    result = host.resolve_action_facts(FactsFixtures::AttributeProcController, %w[show], view_prefix: 'attribute_proc')

    expect(result).to eq({})
  end
end
