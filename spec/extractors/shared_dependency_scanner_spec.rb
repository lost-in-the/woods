# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/model_name_cache'
require 'woods/extractors/shared_dependency_scanner'

RSpec.describe Woods::Extractors::SharedDependencyScanner do
  # Create a test class that includes the module so we can call its methods.
  let(:test_class) do
    Class.new do
      include Woods::Extractors::SharedDependencyScanner
    end
  end

  subject(:scanner) { test_class.new }

  before do
    # Stub ModelNameCache so tests don't require a Rails environment.
    allow(Woods::ModelNameCache).to receive(:model_names_regex)
      .and_return(/\b(?:User|Post)\b/)
  end

  after do
    Woods::ModelNameCache.reset!
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

    it 'ignores fully-qualified references inside comments' do
      source = <<~RUBY
        # TODO: migrate User to the new schema
        post = Post.first
      RUBY
      targets = scanner.scan_model_dependencies(source).map { |d| d[:target] }
      expect(targets).to eq(['Post'])
    end

    it 'still matches references inside string interpolation' do
      # rubocop:disable-next Lint/InterpolationCheck -- the #{} is source under test, not spec interpolation
      source = 'label = "owner: #{User.find(id).name}"'
      targets = scanner.scan_model_dependencies(source).map { |d| d[:target] }
      expect(targets).to eq(['User'])
    end

    it 'keeps a model reference that follows a # inside a string literal' do
      # A literal `#` (URL fragment, hex color, "Tag #ruby") is not a Ruby
      # comment; comment-stripping must be string-literal-aware or the rest
      # of the line — including the model reference — is silently dropped.
      source = 'link_to "Tag #ruby", User.recent'
      targets = scanner.scan_model_dependencies(source).map { |d| d[:target] }
      expect(targets).to eq(['User'])
    end

    it 'strips a real trailing comment while keeping code on the same line' do
      source = 'post = Post.first # see User for the join'
      targets = scanner.scan_model_dependencies(source).map { |d| d[:target] }
      expect(targets).to eq(['Post'])
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

    it 'keeps the namespace of a fully-qualified service reference (EXTA-2)' do
      # `\w+` cannot cross `::`, so the edge targeted a bare `ChargeService`
      # while the unit's own identifier is `Billing::ChargeService` — the
      # edge matched no node and the blast radius never reached the caller.
      source = 'Billing::ChargeService.call(order)'
      result = scanner.scan_service_dependencies(source)
      expect(result.map { |d| d[:target] }).to eq(['Billing::ChargeService'])
    end

    it 'stops the namespace capture at the service constant (EXTA-2)' do
      source = 'Billing::ChargeService::VERSION'
      result = scanner.scan_service_dependencies(source)
      expect(result.map { |d| d[:target] }).to eq(['Billing::ChargeService'])
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

    it 'finds Sidekiq Worker.perform_async patterns (EXTA-4)' do
      # `*Worker` is the dominant Sidekiq naming convention and app/workers
      # is a scanned directory, yet no unit anywhere recorded an edge to one.
      source = 'HardWorker.perform_async(1)'
      result = scanner.scan_job_dependencies(source)
      expect(result.map { |d| d[:target] }).to eq(['HardWorker'])
    end

    it 'finds a delayed .set(...).perform_later chain (EXTA-4)' do
      source = 'SyncJob.set(wait: 5.minutes).perform_later(id)'
      result = scanner.scan_job_dependencies(source)
      expect(result.map { |d| d[:target] }).to eq(['SyncJob'])
    end

    it 'keeps the namespace of a fully-qualified job reference (EXTA-2)' do
      source = 'Billing::SyncJob.perform_later(id)'
      result = scanner.scan_job_dependencies(source)
      expect(result.map { |d| d[:target] }).to eq(['Billing::SyncJob'])
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

    it 'keeps the namespace of a fully-qualified mailer reference (EXTA-2)' do
      source = 'Admin::AlertMailer.alert(user).deliver_later'
      result = scanner.scan_mailer_dependencies(source)
      expect(result.map { |d| d[:target] }).to eq(['Admin::AlertMailer'])
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

  # ── #consolidate_dependencies ────────────────────────────────────

  describe '#consolidate_dependencies' do
    it 'merges multiple dependency arrays' do
      models = [{ type: :model, target: 'User', via: :code_reference }]
      services = [{ type: :service, target: 'BillingService', via: :code_reference }]

      result = scanner.consolidate_dependencies(models, services)
      expect(result).to contain_exactly(
        { type: :model, target: 'User', via: :code_reference },
        { type: :service, target: 'BillingService', via: :code_reference }
      )
    end

    it 'deduplicates by [type, target], keeping the first occurrence' do
      first = { type: :model, target: 'User', via: :belongs_to }
      second = { type: :model, target: 'User', via: :code_reference }

      result = scanner.consolidate_dependencies([first], [second])
      expect(result).to eq([first])
    end

    it 'keeps entries with the same target but different types' do
      deps = [
        { type: :model, target: 'Payment', via: :code_reference },
        { type: :service, target: 'Payment', via: :code_reference }
      ]

      result = scanner.consolidate_dependencies(deps)
      expect(result.size).to eq(2)
    end

    it 'removes nil entries' do
      deps = [{ type: :model, target: 'User', via: :code_reference }, nil]

      result = scanner.consolidate_dependencies(deps)
      expect(result).to eq([{ type: :model, target: 'User', via: :code_reference }])
    end

    it 'accepts a single pre-built array as a drop-in for the inline uniq chain' do
      deps = [
        { type: :model, target: 'User', via: :code_reference },
        { type: :model, target: 'User', via: :render }
      ]

      result = scanner.consolidate_dependencies(deps)
      expect(result.size).to eq(1)
    end

    it 'returns an empty array when given only empty arrays' do
      expect(scanner.consolidate_dependencies([], [])).to eq([])
    end
  end

  # ── #scan_navigation_dependencies ────────────────────────────────

  describe '#scan_navigation_dependencies' do
    let(:nav_test_class) do
      Class.new do
        include Woods::Extractors::SharedDependencyScanner
        include Woods::Extractors::RouteHelperResolver

        def initialize(route_map)
          @route_helper_map = route_map
        end
      end
    end

    let(:route_map) do
      {
        'posts' => { controller: 'PostsController', action: 'index', path: '/posts', verb: 'GET' },
        'new_post' => { controller: 'PostsController', action: 'new', path: '/posts/new', verb: 'GET' },
        'edit_post' => { controller: 'PostsController', action: 'edit', path: '/posts/:id/edit', verb: 'GET' },
        'users' => { controller: 'UsersController', action: 'index', path: '/users', verb: 'GET' }
      }
    end

    subject(:nav_scanner) { nav_test_class.new(route_map) }

    before do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    it 'finds _path route helpers and resolves to controller targets' do
      source = 'link_to "Posts", posts_path'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to include(a_hash_including(target: 'PostsController', via: :link_to))
    end

    it 'finds _url route helpers' do
      source = 'redirect_to posts_url'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to include(a_hash_including(target: 'PostsController'))
    end

    it 'resolves multiple different helpers' do
      source = <<~ERB
        link_to "Posts", posts_path
        link_to "Users", users_path
      ERB
      result = nav_scanner.scan_navigation_dependencies(source)
      targets = result.map { |d| d[:target] }
      expect(targets).to contain_exactly('PostsController', 'UsersController')
    end

    it 'deduplicates same controller via same via type' do
      source = <<~ERB
        link_to "Posts", posts_path
        link_to "New Post", new_post_path
        link_to "Edit", edit_post_path(post)
      ERB
      result = nav_scanner.scan_navigation_dependencies(source)
      posts_deps = result.select { |d| d[:target] == 'PostsController' }
      expect(posts_deps.size).to eq(1)
    end

    it 'accepts a custom via_type' do
      source = 'redirect_to posts_path'
      result = nav_scanner.scan_navigation_dependencies(source, via_type: :redirect_to)
      expect(result.first[:via]).to eq(:redirect_to)
    end

    it 'ignores asset_path helpers' do
      source = 'image_tag asset_path("logo.png")'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to be_empty
    end

    it 'ignores image_path helpers' do
      source = 'image_tag image_path("photo.jpg")'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to be_empty
    end

    it 'skips unresolvable helpers' do
      source = 'link_to "Unknown", totally_unknown_path'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to be_empty
    end

    it 'returns empty when config is disabled' do
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)
      source = 'link_to "Posts", posts_path'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to be_empty
    end

    it 'all returned dependencies have type :controller' do
      source = 'link_to "Posts", posts_path; link_to "Users", users_path'
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to all(satisfy { |d| d[:type] == :controller })
    end

    it 'ignores common false-positive prefixes like file_path and log_url' do
      source = <<~RUBY
        File.read(file_path)
        Logger.new(log_path)
        open(socket_url)
        save_to(tmp_path)
        URI.parse(base_url)
      RUBY
      result = nav_scanner.scan_navigation_dependencies(source)
      expect(result).to be_empty
    end
  end

  # ── #scan_form_dependencies ─────────────────────────────────────

  describe '#scan_form_dependencies' do
    let(:form_test_class) do
      Class.new do
        include Woods::Extractors::SharedDependencyScanner
        include Woods::Extractors::RouteHelperResolver

        def initialize(route_map)
          @route_helper_map = route_map
        end
      end
    end

    let(:route_map) do
      {
        'posts' => { controller: 'PostsController', action: 'create', path: '/posts', verb: 'POST' },
        'users' => { controller: 'UsersController', action: 'create', path: '/users', verb: 'POST' }
      }
    end

    subject(:form_scanner) { form_test_class.new(route_map) }

    before do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    it 'extracts form_with targeting a route helper' do
      source = '<%= form_with url: posts_path do |f| %>'
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to include(a_hash_including(target: 'PostsController', via: :form_action))
    end

    it 'extracts form_for targeting a route helper' do
      source = '<%= form_for @post, url: posts_path do |f| %>'
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to include(a_hash_including(target: 'PostsController', via: :form_action))
    end

    it 'handles multi-line form_with calls' do
      source = <<~ERB
        <%= form_with model: @post,
                      url: posts_path do |f| %>
          <%= f.text_field :title %>
        <% end %>
      ERB
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to include(a_hash_including(target: 'PostsController', via: :form_action))
    end

    it 'handles multi-line form_for calls' do
      source = <<~ERB
        <%= form_for @user,
                     url: users_path,
                     html: { class: "form" } do |f| %>
          <%= f.text_field :name %>
        <% end %>
      ERB
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to include(a_hash_including(target: 'UsersController', via: :form_action))
    end

    it 'deduplicates same controller' do
      source = <<~ERB
        <%= form_with url: posts_path do |f| %>
        <%= form_with url: posts_path do |f| %>
      ERB
      result = form_scanner.scan_form_dependencies(source)
      expect(result.size).to eq(1)
    end

    it 'returns empty when config is disabled' do
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)
      source = '<%= form_with url: posts_path do |f| %>'
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to be_empty
    end

    it 'skips unresolvable helpers' do
      source = '<%= form_with url: nonexistent_path do |f| %>'
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to be_empty
    end

    it 'all returned dependencies have via :form_action' do
      source = '<%= form_with url: posts_path do |f| %>'
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to all(satisfy { |d| d[:via] == :form_action })
    end

    # Plain Ruby sources (Phlex, ViewComponent, mailers) have no `%` at all,
    # so a `[^%]`-bounded scan ran straight past this form's own `do` block
    # and attributed an unrelated later route helper to it.
    it 'does not attribute an unrelated later path helper in plain Ruby source with no % characters' do
      source = <<~RUBY
        def render_form
          form_with model: @post do |f|
            f.submit
          end
          href = posts_path
        end
      RUBY
      result = form_scanner.scan_form_dependencies(source)
      expect(result).to be_empty
    end
  end

  # ── Graph resolution: constantize + short names (fills a graph gap where
  #    bare short-name / string-literal refs produced zero dependents) ──

  describe 'constantize / short-name resolution' do
    it 'resolves .constantize string-literal arguments to model targets' do
      allow(Woods::ModelNameCache).to receive(:model_names).and_return(%w[User Library::Book])

      source = '"Library::Book".constantize.new'
      result = scanner.scan_model_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('Library::Book')
    end

    it 'resolves const_get(...) string-literal arguments to model targets' do
      allow(Woods::ModelNameCache).to receive(:model_names).and_return(%w[User Library::Book])

      source = 'klass = Object.const_get("Library::Book")'
      result = scanner.scan_model_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('Library::Book')
    end

    it 'ignores .constantize on unknown string literals' do
      allow(Woods::ModelNameCache).to receive(:model_names).and_return(%w[User])

      source = '"NotAModel".constantize'
      result = scanner.scan_model_dependencies(source)
      expect(result).to be_empty
    end

    it 'resolves bare short names to fully-qualified owners when unambiguous' do
      allow(Woods::ModelNameCache).to receive(:model_names).and_return(%w[Library::Book])
      allow(Woods::ModelNameCache).to receive(:short_names_regex)
        .and_return(/(?<![:.\w])Book\b(?=\s*(?:\.|::|\(|,|\)|\]|=(?!=)|$))/)
      allow(Woods::ModelNameCache).to receive(:resolve_short_name)
        .with('Book').and_return('Library::Book')

      source = 'Book.new(isbn: "x")'
      result = scanner.scan_model_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('Library::Book')
    end

    it 'preserves Ruby string interpolation (#{...}) when stripping comments' do
      # Regression: an earlier iteration used `gsub(/#[^\n]*/, '')` which
      # also consumed every `#{interpolation}`, wiping short-name refs
      # inside ERB/Phlex/string templates like `"Book: #{Book.name}"`.
      allow(Woods::ModelNameCache).to receive(:model_names).and_return(%w[Library::Book])
      allow(Woods::ModelNameCache).to receive(:short_names_regex)
        .and_return(/(?<![:.\w])Book\b(?=\s*(?:\.|::|\(|,|\)|\]|=(?!=)|$))/)
      allow(Woods::ModelNameCache).to receive(:resolve_short_name)
        .with('Book').and_return('Library::Book')

      # The source string deliberately contains the literal characters
      # `#{Book.name}` so the scanner sees what an ERB/Phlex template
      # would emit at runtime — we are NOT evaluating the interpolation
      # here.
      source = "<%= \"Current: \#{Book.name}\" %>"
      result = scanner.scan_model_dependencies(source)
      expect(result.map { |d| d[:target] }).to include('Library::Book')
    end

    it 'strips `#` line comments before short-name scanning (no ghost edges)' do
      allow(Woods::ModelNameCache).to receive(:model_names).and_return(%w[Library::Book])
      allow(Woods::ModelNameCache).to receive(:short_names_regex)
        .and_return(/(?<![:.\w])Book\b(?=\s*(?:\.|::|\(|,|\)|\]|=(?!=)|$))/)
      # Scanner must NOT ask the cache to resolve a name pulled out of
      # a comment — if it does, the test fails loudly.
      expect(Woods::ModelNameCache).not_to receive(:resolve_short_name)

      source = "# TODO: rewrite Book.new later\nUser.find(1)\n"
      scanner.scan_model_dependencies(source)
    end
  end
end
