# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extractors/action_facts'

# What one action or filter body says, read from the syntax tree (W-7,
# woods#757): instance variables it assigns, params it reads, what it
# renders, where it redirects, the formats it responds to.
RSpec.describe Woods::Extractors::ActionFacts do
  def facts(source, name, line: nil, view_prefix: 'users', permitted: [], mailer: false)
    program = Prism.parse(source).value
    node = described_class.definition(program, name, line)
    described_class.scan(node, view_prefix: view_prefix, permitted: permitted, mailer: mailer)
  end

  let(:controller) do
    <<~RUBY
      class UsersController < ApplicationController
        def show
          @user = User.find(params[:id])
          @microposts ||= @user.microposts.paginate(page: params.fetch(:page, 1))
          # @ghost = nil, and render :ghost, in a comment
          note = "@quoted = 1; render :quoted"
        end

        def create
          @user = User.new(user_params)
          if @user.save
            redirect_to @user, status: :see_other
          else
            render :new, status: :unprocessable_entity
          end
        end

        def update
          @count += 1
          @a, @b = params.require(:pair)
          respond_to do |format|
            format.html { redirect_back(fallback_location: root_path) }
            format.json { render json: @user }
          end
        end

        def edit
          render partial: 'form', locals: { user: @user, title: 'Edit' }
        end

        def destroy
          params[:user][:name]
          params.expect(post: [:title])
          head :no_content
        end

        def shared
          render 'shared/stats'
          render template: 'users/index'
        end

        def show
          @redefined = true
        end
      end
    RUBY
  end

  it 'records each instance variable an action assigns, with its line, and nothing from comments or strings' do
    show = facts(controller, 'show', line: 2)
    expect(show[:assigns]).to eq([{ ivar: '@user', line: 3 }, { ivar: '@microposts', line: 4 }])
  end

  it 'reads every assignment form: operator, or-write and multiple assignment' do
    update = facts(controller, 'update')
    expect(update[:assigns]).to eq([{ ivar: '@count', line: 19 }, { ivar: '@a', line: 20 }, { ivar: '@b', line: 20 }])
  end

  it 'records the params an action reads, once per key and line, and calls to a permitted-params method' do
    show = facts(controller, 'show', line: 2)
    expect(show[:params]).to eq([{ key: 'id', line: 3, permitted: false }, { key: 'page', line: 4, permitted: false }])
    create = facts(controller, 'create', permitted: { 'user_params' => 'user' })
    expect(create[:params]).to eq([{ key: 'user', line: 10, permitted: true, via: 'user_params' }])
    destroy = facts(controller, 'destroy')
    expect(destroy[:params].map { |p| p[:key] }).to eq(%w[user post])
  end

  it 'names explicit renders with the template, partial, locals, format and status they ask for' do
    create = facts(controller, 'create')
    expect(create[:renders]).to eq([{ template: 'users/new', line: 14, status: 'unprocessable_entity' }])
    edit = facts(controller, 'edit')
    expect(edit[:renders]).to eq([{ partial: 'users/_form', locals: %w[user title], line: 28 }])
    shared = facts(controller, 'shared')
    expect(shared[:renders].map { |r| r[:template] }).to eq(%w[shared/stats users/index])
    expect(facts(controller, 'update')[:renders]).to eq([{ format: 'json', line: 23 }])
    expect(facts(controller, 'destroy')[:renders]).to eq([{ head: 'no_content', line: 34 }])
  end

  it 'adds the implicit render when the body neither renders, redirects nor heads' do
    show = facts(controller, 'show', line: 2)
    expect(show[:renders]).to eq([{ template: 'users/show', implicit: true }])
    expect(facts(controller, 'create')[:renders].none? { |r| r[:implicit] }).to be(true)
  end

  it 'records redirects with their target as written' do
    expect(facts(controller, 'create')[:redirects]).to eq([{ target: '@user', line: 12 }])
    expect(facts(controller, 'update')[:redirects]).to eq([{ target: 'back', line: 22 }])
  end

  it 'records the formats a respond_to block names' do
    expect(facts(controller, 'update')[:formats]).to eq(%w[html json])
    expect(facts(controller, 'show', line: 2)[:formats]).to eq([])
  end

  it 'takes the definition at the line Ruby reports and requires a match when a line is supplied' do
    expect(facts(controller, 'show', line: 42)[:assigns]).to eq([{ ivar: '@redefined', line: 43 }])
    expect(described_class.definition(Prism.parse(controller).value, 'show', 99)).to be_nil
    expect(described_class.definition(Prism.parse(controller).value, 'edit', 99)).to be_nil
    expect(described_class.definition(Prism.parse(controller).value, 'edit', nil)).not_to be_nil
  end

  it 'leaves same-name definitions sharing a source line unresolved' do
    source = 'class One; def show; @one = true; end; end; class Two; def show; @two = true; end; end'

    expect(described_class.definition(Prism.parse(source).value, 'show', 1)).to be_nil
  end

  it 'keeps runtime and source-only lookup unresolved on a dynamic generation source line' do
    source = 'class One; define_method(action_name) {}; end; class Two; def show; @wrong = true; end; end'
    definitions = described_class.definitions(Prism.parse(source).value)

    expect(described_class.definition(definitions, 'show', 1)).to be_nil
    expect(described_class.definition(definitions, 'show', nil)).to be_nil
  end

  it 'ignores splatted expect keys while recording literal keys beside them' do
    source = 'def show; params.expect(**schema); params.expect(**schema, user: [:name]); end'

    expect(facts(source, 'show')[:params]).to eq([{ key: 'user', line: 1, permitted: false }])
  end

  it 'reads explicit self responses, params and respond_to just like receiverless calls' do
    source = <<~RUBY
      def show
        @user = self.params[:id]
        self.respond_to do |format|
          format.html { self.render :new }
          format.json { self.head :no_content }
        end
        self.redirect_to root_path
      end
    RUBY
    show = facts(source, 'show')

    expect(show[:params]).to eq([{ key: 'id', line: 2, permitted: false }])
    expect(show[:formats]).to eq(%w[html json])
    expect(show[:renders]).to eq([{ template: 'users/new', line: 4 }, { head: 'no_content', line: 5 }])
    expect(show[:redirects]).to eq([{ target: 'root_path', line: 7 }])
  end

  it 'does not borrow assigns or responses from nested definitions or class bodies' do
    source = <<~RUBY
      def show
        def later
          @deferred = true
          render :deferred
        end
        ::Class.new do
          @class_state = params[:class_state]
          def nested; render :nested; end
        end
        Module.new { @module_state = true }
        class << self
          @singleton_state = true
        end
        @actual = params[:id]
      end
    RUBY
    show = facts(source, 'show')

    expect(show[:assigns]).to eq([{ ivar: '@actual', line: 14 }])
    expect(show[:params]).to eq([{ key: 'id', line: 14, permitted: false }])
    expect(show[:renders]).to eq([{ template: 'users/show', implicit: true }])
  end

  it 'retains dynamic response expressions without inventing a template or partial' do
    source = <<~RUBY
      def show
        render template: params[:view]
        render action: next_action
        render partial: @partial_name, locals: { user: @user }
      end
    RUBY

    expect(facts(source, 'show')[:renders]).to eq(
      [{ object: 'params[:view]', line: 2 },
       { object: 'next_action', line: 3 },
       { object: '@partial_name', line: 4 }]
    )
  end

  it 'does not substitute the default mail template for a dynamic explicit target' do
    source = <<~RUBY
      def digest
        self.mail(template_name: chosen_template)
        mail(template_path: view_paths)
      end
    RUBY

    expect(facts(source, 'digest', mailer: true)[:renders]).to eq(
      [{ object: 'self.mail(template_name: chosen_template)', line: 2, mail: true },
       { object: 'mail(template_path: view_paths)', line: 3, mail: true }]
    )
  end

  it 'does not attribute foreign eval or exec block bodies to the action' do
    source = <<~RUBY
      def show
        (@receiver = params[:receiver]).instance_exec(@argument = params[:argument]) do
          @foreign = params[:foreign]
          render :foreign
        end
        other.instance_eval { @foreign_eval = true; head :no_content }
        self.class.class_eval { @class_state = true; render :class_state }
        other.class_exec { @class_exec = true; redirect_to root_path }
        other.module_eval { @module_eval = true; render :module_eval }
        other.module_exec { @module_exec = true; render :module_exec }
      end
    RUBY
    show = facts(source, 'show')

    expect(show[:assigns]).to eq([{ ivar: '@receiver', line: 2 }, { ivar: '@argument', line: 2 }])
    expect(show[:params].map { |entry| entry[:key] }).to eq(%w[receiver argument])
    expect(show[:renders]).to eq([{ template: 'users/show', implicit: true }])
    expect(show[:redirects]).to eq([])
  end

  it 'keeps eval and exec blocks on self in the action scope' do
    source = <<~RUBY
      def show
        self.instance_eval { @own = params[:id] }
        instance_exec { render :own }
      end
    RUBY
    show = facts(source, 'show')

    expect(show[:assigns]).to eq([{ ivar: '@own', line: 2 }])
    expect(show[:params]).to eq([{ key: 'id', line: 2, permitted: false }])
    expect(show[:renders]).to eq([{ template: 'users/own', line: 3 }])
  end

  it 'records numeric response statuses without treating numbers as template names' do
    source = 'def show; render :new, status: 422; head 204; render template: 123; end'

    expect(facts(source, 'show')[:renders]).to eq(
      [{ template: 'users/new', line: 1, status: 422 }, { head: '204', line: 1 }, { object: '123', line: 1 }]
    )
  end

  it 'reads a mailer action: the template mail renders, implicit or named' do
    mailer = <<~RUBY
      class UserMailer < ApplicationMailer
        def account_activation(user)
          @user = user
          mail to: user.email, subject: 'Account activation'
        end

        def digest(user)
          @user = user
          mail(to: user.email, template_name: 'weekly')
        end
      end
    RUBY
    activation = facts(mailer, 'account_activation', view_prefix: 'user_mailer', mailer: true)
    expect(activation[:assigns]).to eq([{ ivar: '@user', line: 3 }])
    expect(activation[:renders]).to eq([{ template: 'user_mailer/account_activation', line: 4, mail: true }])
    digest = facts(mailer, 'digest', view_prefix: 'user_mailer', mailer: true)
    expect(digest[:renders]).to eq([{ template: 'user_mailer/weekly', line: 9, mail: true }])
  end
end
