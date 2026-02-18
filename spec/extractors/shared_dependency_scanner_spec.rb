# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/shared_dependency_scanner'

RSpec.describe CodebaseIndex::Extractors::SharedDependencyScanner do
  # Create a test class that includes the module so we can call its methods.
  let(:test_class) do
    Class.new do
      include CodebaseIndex::Extractors::SharedDependencyScanner
    end
  end

  subject(:scanner) { test_class.new }

  before do
    # Stub ModelNameCache so tests don't require a Rails environment.
    allow(CodebaseIndex::ModelNameCache).to receive(:model_names_regex)
      .and_return(/\b(?:User|Post)\b/)
  end

  after do
    CodebaseIndex::ModelNameCache.reset!
  end

  # ── #scan_model_dependencies ────────────────────────────────────

  describe '#scan_model_dependencies' do
    it 'finds model references in source code' do
      source = 'user = User.find(1); post = Post.first'
      result = scanner.scan_model_dependencies(source)
      targets = result.map { |d| d[:target] }
      expect(targets).to include('User', 'Post')
    end

    it 'returns hashes with type :model' do
      source = 'User.create(name: "test")'
      result = scanner.scan_model_dependencies(source)
      expect(result.first[:type]).to eq(:model)
    end

    it 'uses :code_reference as the default via label' do
      source = 'User.find(1)'
      result = scanner.scan_model_dependencies(source)
      expect(result.first[:via]).to eq(:code_reference)
    end

    it 'accepts a custom via label' do
      source = 'User.find(1)'
      result = scanner.scan_model_dependencies(source, via: :serialization)
      expect(result.first[:via]).to eq(:serialization)
    end

    it 'deduplicates repeated model references' do
      source = 'User.find(1); User.find(2); User.all'
      result = scanner.scan_model_dependencies(source)
      user_deps = result.select { |d| d[:target] == 'User' }
      expect(user_deps.size).to eq(1)
    end

    it 'returns empty array when no model references found' do
      source = 'class Foo; end'
      result = scanner.scan_model_dependencies(source)
      expect(result).to eq([])
    end
  end

  # ── #scan_service_dependencies ──────────────────────────────────

  describe '#scan_service_dependencies' do
    it 'finds Service.call patterns' do
      source = 'PaymentService.call(order: order)'
      result = scanner.scan_service_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('PaymentService')
    end

    it 'finds Service::new patterns' do
      source = 'NotificationService::new(user: user)'
      result = scanner.scan_service_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('NotificationService')
    end

    it 'returns hashes with type :service' do
      source = 'BillingService.call'
      result = scanner.scan_service_dependencies(source)
      expect(result.first[:type]).to eq(:service)
    end

    it 'uses :code_reference as the default via label' do
      source = 'FooService.call'
      result = scanner.scan_service_dependencies(source)
      expect(result.first[:via]).to eq(:code_reference)
    end

    it 'accepts a custom via label' do
      source = 'FooService.call'
      result = scanner.scan_service_dependencies(source, via: :delegation)
      expect(result.first[:via]).to eq(:delegation)
    end

    it 'deduplicates repeated service references' do
      source = 'FooService.call; FooService.new'
      result = scanner.scan_service_dependencies(source)
      foo_deps = result.select { |d| d[:target] == 'FooService' }
      expect(foo_deps.size).to eq(1)
    end

    it 'returns empty array when no service references found' do
      source = 'class Foo; end'
      result = scanner.scan_service_dependencies(source)
      expect(result).to eq([])
    end
  end

  # ── #scan_job_dependencies ──────────────────────────────────────

  describe '#scan_job_dependencies' do
    it 'finds Job.perform_later patterns' do
      source = 'SendEmailJob.perform_later(user_id: user.id)'
      result = scanner.scan_job_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('SendEmailJob')
    end

    it 'finds Job.perform_async patterns' do
      source = 'ProcessOrderJob.perform_async(order.id)'
      result = scanner.scan_job_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('ProcessOrderJob')
    end

    it 'returns hashes with type :job' do
      source = 'CleanupJob.perform_later'
      result = scanner.scan_job_dependencies(source)
      expect(result.first[:type]).to eq(:job)
    end

    it 'uses :code_reference as the default via label' do
      source = 'FooJob.perform_later'
      result = scanner.scan_job_dependencies(source)
      expect(result.first[:via]).to eq(:code_reference)
    end

    it 'accepts a custom via label' do
      source = 'FooJob.perform_later'
      result = scanner.scan_job_dependencies(source, via: :background)
      expect(result.first[:via]).to eq(:background)
    end

    it 'deduplicates repeated job references' do
      source = 'FooJob.perform_later; FooJob.perform_async'
      result = scanner.scan_job_dependencies(source)
      foo_deps = result.select { |d| d[:target] == 'FooJob' }
      expect(foo_deps.size).to eq(1)
    end

    it 'returns empty array when no job references found' do
      source = 'class Foo; end'
      result = scanner.scan_job_dependencies(source)
      expect(result).to eq([])
    end
  end

  # ── #scan_mailer_dependencies ────────────────────────────────────

  describe '#scan_mailer_dependencies' do
    it 'finds Mailer.method patterns' do
      source = 'UserMailer.welcome_email(user).deliver_later'
      result = scanner.scan_mailer_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('UserMailer')
    end

    it 'returns hashes with type :mailer' do
      source = 'OrderMailer.confirmation(order)'
      result = scanner.scan_mailer_dependencies(source)
      expect(result.first[:type]).to eq(:mailer)
    end

    it 'uses :code_reference as the default via label' do
      source = 'FooMailer.bar'
      result = scanner.scan_mailer_dependencies(source)
      expect(result.first[:via]).to eq(:code_reference)
    end

    it 'accepts a custom via label' do
      source = 'FooMailer.bar'
      result = scanner.scan_mailer_dependencies(source, via: :notification)
      expect(result.first[:via]).to eq(:notification)
    end

    it 'deduplicates repeated mailer references' do
      source = 'FooMailer.welcome; FooMailer.goodbye'
      result = scanner.scan_mailer_dependencies(source)
      foo_deps = result.select { |d| d[:target] == 'FooMailer' }
      expect(foo_deps.size).to eq(1)
    end

    it 'returns empty array when no mailer references found' do
      source = 'class Foo; end'
      result = scanner.scan_mailer_dependencies(source)
      expect(result).to eq([])
    end
  end

  # ── #scan_common_dependencies ────────────────────────────────────

  describe '#scan_common_dependencies' do
    it 'combines model, service, job, and mailer dependencies' do
      source = <<~RUBY
        user = User.find(1)
        BillingService.call(user: user)
        SendEmailJob.perform_later(user_id: user.id)
        UserMailer.welcome(user).deliver_later
      RUBY

      result = scanner.scan_common_dependencies(source)
      types = result.map { |d| d[:type] }
      expect(types).to include(:model, :service, :job, :mailer)
    end

    it 'deduplicates across all dependency types' do
      source = <<~RUBY
        User.find(1)
        User.all
        BillingService.call
        BillingService.new
      RUBY

      result = scanner.scan_common_dependencies(source)
      user_deps = result.select { |d| d[:type] == :model && d[:target] == 'User' }
      billing_deps = result.select { |d| d[:type] == :service && d[:target] == 'BillingService' }
      expect(user_deps.size).to eq(1)
      expect(billing_deps.size).to eq(1)
    end

    it 'returns empty array when source has no known dependencies' do
      source = 'class Foo; def bar; 42; end; end'
      result = scanner.scan_common_dependencies(source)
      expect(result).to eq([])
    end

    it 'all returned dependencies use :code_reference via' do
      source = <<~RUBY
        User.find(1)
        FooService.call
        BarJob.perform_later
        BazMailer.notify
      RUBY

      result = scanner.scan_common_dependencies(source)
      expect(result).to all(satisfy { |d| d[:via] == :code_reference })
    end
  end
end
