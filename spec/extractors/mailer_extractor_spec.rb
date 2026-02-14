# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/mailer_extractor'

RSpec.describe CodebaseIndex::Extractors::MailerExtractor do
  include_context 'extractor setup'

  # ── Test doubles ──────────────────────────────────────────────────────

  def build_action_filter(actions)
    obj = Object.new
    obj.instance_variable_set(:@actions, Set.new(actions.map(&:to_s)))
    obj
  end

  def build_callback(kind:, filter:, if_conditions: [], unless_conditions: [])
    obj = Object.new
    obj.instance_variable_set(:@if, if_conditions)
    obj.instance_variable_set(:@unless, unless_conditions)
    obj.define_singleton_method(:kind) { kind }
    obj.define_singleton_method(:filter) { filter }
    obj
  end

  let(:action_mailer_base) do
    klass = Class.new
    klass.define_singleton_method(:name) { 'ActionMailer::Base' }
    klass.define_singleton_method(:descendants) { [] }
    klass
  end

  let(:application_mailer) do
    klass = Class.new
    klass.define_singleton_method(:name) { 'ApplicationMailer' }
    klass.define_singleton_method(:descendants) { [] }
    klass
  end

  before do
    stub_const('ActionMailer::Base', action_mailer_base)
    stub_const('ApplicationMailer', application_mailer)
  end

  # ── Helper to build a mock mailer ─────────────────────────────────────

  def build_mailer(name:, actions: [], defaults: {}, delivery_method: :smtp, callbacks: [], instance_methods_list: [])
    klass = Class.new
    klass.define_singleton_method(:name) { name }
    klass.define_singleton_method(:action_methods) { Set.new(actions) }
    klass.define_singleton_method(:default) { defaults }
    klass.define_singleton_method(:delivery_method) { delivery_method }
    klass.define_singleton_method(:_process_action_callbacks) { callbacks }
    klass.define_singleton_method(:instance_methods) { |_inherit = true| instance_methods_list }
    klass
  end

  # ── extract_all ───────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'extracts all mailers from descendants' do
      mailer1 = build_mailer(name: 'UserMailer', actions: %w[welcome_email])
      mailer2 = build_mailer(name: 'OrderMailer', actions: %w[confirmation])

      allow(application_mailer).to receive(:descendants).and_return([mailer1, mailer2])

      # Stub source file resolution — no instance methods, fall back to path
      units = described_class.new.extract_all

      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('UserMailer', 'OrderMailer')
    end

    it 'skips mailers with nil name' do
      anon_mailer = build_mailer(name: nil, actions: [])
      # Override the name method to return nil
      anon_mailer.define_singleton_method(:name) { nil }

      allow(application_mailer).to receive(:descendants).and_return([anon_mailer])

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'skips ActionMailer::Base itself' do
      allow(application_mailer).to receive(:descendants).and_return([action_mailer_base])

      units = described_class.new.extract_all
      expect(units).to be_empty
    end

    it 'returns empty array when no descendants' do
      allow(application_mailer).to receive(:descendants).and_return([])

      units = described_class.new.extract_all
      expect(units).to eq([])
    end
  end

  # ── extract_mailer ────────────────────────────────────────────────────

  describe '#extract_mailer' do
    let(:source) do
      <<~RUBY
        class UserMailer < ApplicationMailer
          default from: 'noreply@example.com'

          helper :users

          layout 'mailer'

          def welcome_email
            @user = params[:user]
            mail(to: @user.email, subject: 'Welcome!')
          end

          def reset_password
            @user = params[:user]
            mail(to: @user.email, subject: 'Reset your password')
          end
        end
      RUBY
    end

    let(:mailer) do
      build_mailer(
        name: 'UserMailer',
        actions: %w[welcome_email reset_password],
        defaults: { from: 'noreply@example.com' },
        delivery_method: :smtp,
        callbacks: []
      )
    end

    before do
      create_file('app/mailers/user_mailer.rb', source)
    end

    it 'produces an ExtractedUnit with correct type and identifier' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit).to be_a(CodebaseIndex::ExtractedUnit)
      expect(unit.type).to eq(:mailer)
      expect(unit.identifier).to eq('UserMailer')
    end

    it 'extracts metadata with actions' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:actions]).to contain_exactly('welcome_email', 'reset_password')
    end

    it 'extracts default settings' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:defaults][:from]).to eq('noreply@example.com')
    end

    it 'extracts delivery method' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:delivery_method]).to eq(:smtp)
    end

    it 'extracts layout from source' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:layout]).to eq('mailer')
    end

    it 'extracts helpers from source' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:helpers]).to include('users')
    end

    it 'includes action count' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:action_count]).to eq(2)
    end

    it 'includes LOC count' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:loc]).to be > 0
    end

    it 'annotates source with header' do
      unit = described_class.new.extract_mailer(mailer)

      expect(unit.source_code).to include('Mailer: UserMailer')
      expect(unit.source_code).to include('Actions:')
      expect(unit.source_code).to include('Default From: noreply@example.com')
    end

    it 'returns nil for mailer with nil name' do
      nil_mailer = build_mailer(name: nil, actions: [])
      nil_mailer.define_singleton_method(:name) { nil }

      unit = described_class.new.extract_mailer(nil_mailer)
      expect(unit).to be_nil
    end

    it 'returns nil for ActionMailer::Base itself' do
      unit = described_class.new.extract_mailer(action_mailer_base)
      expect(unit).to be_nil
    end

    it 'handles errors gracefully' do
      broken_mailer = build_mailer(name: 'BrokenMailer', actions: %w[send_email])
      broken_mailer.define_singleton_method(:action_methods) { raise StandardError, 'boom' }

      unit = described_class.new.extract_mailer(broken_mailer)
      expect(unit).to be_nil
    end
  end

  # ── Callbacks ─────────────────────────────────────────────────────────

  describe 'callback extraction' do
    it 'extracts before_action callbacks' do
      cb = build_callback(kind: :before, filter: :set_user)
      mailer = build_mailer(
        name: 'NotificationMailer',
        actions: %w[notify],
        callbacks: [cb]
      )
      create_file('app/mailers/notification_mailer.rb', "class NotificationMailer < ApplicationMailer\nend\n")

      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:callbacks].size).to eq(1)
      expect(unit.metadata[:callbacks].first[:type]).to eq(:before_action)
      expect(unit.metadata[:callbacks].first[:filter]).to eq('set_user')
    end

    it 'extracts callback with :only condition' do
      action_filter = build_action_filter(%w[welcome_email])
      cb = build_callback(kind: :before, filter: :set_locale, if_conditions: [action_filter])
      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email], callbacks: [cb])
      create_file('app/mailers/user_mailer.rb', "class UserMailer < ApplicationMailer\nend\n")

      unit = described_class.new.extract_mailer(mailer)

      callback = unit.metadata[:callbacks].first
      expect(callback[:only]).to eq(%w[welcome_email])
    end

    it 'extracts callback with :except condition' do
      action_filter = build_action_filter(%w[internal_report])
      cb = build_callback(kind: :after, filter: :log_delivery, unless_conditions: [action_filter])
      mailer = build_mailer(name: 'ReportMailer', actions: %w[daily internal_report], callbacks: [cb])
      create_file('app/mailers/report_mailer.rb', "class ReportMailer < ApplicationMailer\nend\n")

      unit = described_class.new.extract_mailer(mailer)

      callback = unit.metadata[:callbacks].first
      expect(callback[:except]).to eq(%w[internal_report])
    end
  end

  # ── Template Discovery ────────────────────────────────────────────────

  describe 'template discovery' do
    it 'discovers HTML and text templates' do
      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email])

      create_file('app/mailers/user_mailer.rb', "class UserMailer < ApplicationMailer\nend\n")
      create_file('app/views/user_mailer/welcome_email.html.erb', '<h1>Welcome</h1>')
      create_file('app/views/user_mailer/welcome_email.text.erb', 'Welcome')

      unit = described_class.new.extract_mailer(mailer)

      templates = unit.metadata[:templates]
      expect(templates).to have_key('welcome_email')
      expect(templates['welcome_email']).to include('app/views/user_mailer/welcome_email.html.erb')
      expect(templates['welcome_email']).to include('app/views/user_mailer/welcome_email.text.erb')
    end

    it 'discovers slim templates' do
      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email])

      create_file('app/mailers/user_mailer.rb', "class UserMailer < ApplicationMailer\nend\n")
      create_file('app/views/user_mailer/welcome_email.html.slim', 'h1 Welcome')

      unit = described_class.new.extract_mailer(mailer)

      templates = unit.metadata[:templates]
      expect(templates['welcome_email']).to include('app/views/user_mailer/welcome_email.html.slim')
    end

    it 'returns empty hash when no templates found' do
      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email])
      create_file('app/mailers/user_mailer.rb', "class UserMailer < ApplicationMailer\nend\n")

      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:templates]).to be_empty
    end
  end

  # ── Action Chunks ─────────────────────────────────────────────────────

  describe 'action chunks' do
    it 'builds chunks for each action with extractable source' do
      mailer_source = <<~RUBY
        class UserMailer < ApplicationMailer
          def welcome_email
            @user = params[:user]
            mail(to: @user.email, subject: 'Welcome!')
          end
        end
      RUBY

      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email])
      create_file('app/mailers/user_mailer.rb', mailer_source)

      # Stub extract_action_source to return the method body
      extractor = described_class.new
      allow(extractor).to receive(:extract_action_source).with(mailer, 'welcome_email').and_return(
        "def welcome_email\n  @user = params[:user]\n  mail(to: @user.email, subject: 'Welcome!')\nend"
      )

      # Use send to call private build_action_chunks
      chunks = extractor.send(:build_action_chunks, mailer, mailer_source)

      expect(chunks.size).to eq(1)
      expect(chunks.first[:chunk_type]).to eq(:mail_action)
      expect(chunks.first[:identifier]).to eq('UserMailer#welcome_email')
      expect(chunks.first[:content]).to include('Mailer: UserMailer')
      expect(chunks.first[:content]).to include('Action: welcome_email')
      expect(chunks.first[:content_hash]).to be_a(String)
      expect(chunks.first[:metadata][:parent]).to eq('UserMailer')
      expect(chunks.first[:metadata][:action]).to eq('welcome_email')
    end

    it 'skips actions with nil or empty source' do
      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email])
      create_file('app/mailers/user_mailer.rb', "class UserMailer < ApplicationMailer\nend\n")

      extractor = described_class.new
      allow(extractor).to receive(:extract_action_source).and_return(nil)

      chunks = extractor.send(:build_action_chunks, mailer, '')
      expect(chunks).to be_empty
    end
  end

  # ── Dependencies ──────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it 'detects service dependencies' do
      source = <<~RUBY
        class OrderMailer < ApplicationMailer
          def receipt
            @order = params[:order]
            PricingService.calculate(@order)
            mail(to: @order.user.email)
          end
        end
      RUBY

      mailer = build_mailer(name: 'OrderMailer', actions: %w[receipt])
      create_file('app/mailers/order_mailer.rb', source)

      unit = described_class.new.extract_mailer(mailer)

      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.map { |d| d[:target] }).to include('PricingService')
    end

    it 'detects URL helper route dependencies' do
      source = <<~RUBY
        class UserMailer < ApplicationMailer
          def welcome_email
            @url = confirmation_url(token: 'abc')
            @profile = edit_user_path(@user)
            mail(to: 'user@example.com')
          end
        end
      RUBY

      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome_email])
      create_file('app/mailers/user_mailer.rb', source)

      unit = described_class.new.extract_mailer(mailer)

      route_deps = unit.dependencies.select { |d| d[:type] == :route }
      targets = route_deps.map { |d| d[:target] }
      expect(targets).to include('confirmation')
      expect(targets).to include('edit_user')
    end
  end

  describe 'all dependencies have :via key' do
    it 'includes :via key on all dependencies' do
      source = <<~RUBY
        class OrderMailer < ApplicationMailer
          def receipt
            PricingService.calculate(params[:order])
            mail(to: 'user@example.com')
          end
        end
      RUBY

      mailer = build_mailer(name: 'OrderMailer', actions: %w[receipt])
      create_file('app/mailers/order_mailer.rb', source)

      unit = described_class.new.extract_mailer(mailer)

      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Namespace ─────────────────────────────────────────────────────────

  describe 'namespace extraction' do
    it 'extracts namespace for namespaced mailer' do
      mailer = build_mailer(name: 'Admin::NotificationMailer', actions: %w[alert])
      create_file('app/mailers/admin/notification_mailer.rb',
                  "class Admin::NotificationMailer < ApplicationMailer\nend\n")

      unit = described_class.new.extract_mailer(mailer)

      expect(unit.namespace).to eq('Admin')
    end

    it 'returns nil namespace for top-level mailer' do
      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome])
      create_file('app/mailers/user_mailer.rb', "class UserMailer < ApplicationMailer\nend\n")

      unit = described_class.new.extract_mailer(mailer)

      expect(unit.namespace).to be_nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  describe 'helper extraction' do
    it 'detects helper declarations' do
      source = <<~RUBY
        class UserMailer < ApplicationMailer
          helper :formatting
          helper :users

          def welcome
            mail(to: 'user@example.com')
          end
        end
      RUBY

      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome])
      create_file('app/mailers/user_mailer.rb', source)

      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:helpers]).to include('formatting', 'users')
    end

    it 'detects include helper modules' do
      source = <<~RUBY
        class UserMailer < ApplicationMailer
          include UrlHelper

          def welcome
            mail(to: 'user@example.com')
          end
        end
      RUBY

      mailer = build_mailer(name: 'UserMailer', actions: %w[welcome])
      create_file('app/mailers/user_mailer.rb', source)

      unit = described_class.new.extract_mailer(mailer)

      expect(unit.metadata[:helpers]).to include('UrlHelper')
    end
  end

  # ── Fallback to ActionMailer::Base ────────────────────────────────────

  describe 'initialization' do
    it 'falls back to ActionMailer::Base when ApplicationMailer is not defined' do
      # Temporarily hide ApplicationMailer
      hide_const('ApplicationMailer')

      mailer = build_mailer(name: 'DirectMailer', actions: %w[send_email])
      allow(action_mailer_base).to receive(:descendants).and_return([mailer])

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('DirectMailer')
    end
  end
end
