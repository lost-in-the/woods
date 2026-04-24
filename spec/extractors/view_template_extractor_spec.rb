# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/model_name_cache'
require 'woods/extractors/view_template_extractor'

RSpec.describe Woods::Extractors::ViewTemplateExtractor do
  include_context 'extractor setup'

  # Stub engine implementing the ViewEngines::Base contract. Reused by
  # the supported_template_engines aggregation tests and the engine
  # dispatch tests below.
  let(:fake_engine_class) do
    Class.new(Woods::Extractors::ViewEngines::Base) do
      def name
        :fake
      end

      def extensions
        ['.fake']
      end

      def scan_partials(_source)
        []
      end

      def scan_instance_variables(_source)
        []
      end

      def scan_helpers(_source)
        ['fake_helper']
      end

      def resolve_partial_identifier(partial_name, _current_identifier)
        "_#{partial_name}.fake"
      end

      def scan_navigation_candidates(_source)
        []
      end
    end
  end

  describe '.supported_template_engines' do
    it 'returns the engine names currently wired into the orchestrator' do
      expect(described_class.supported_template_engines).to eq([:erb])
    end

    it 'is aggregated from ENGINES — adding an engine extends the list' do
      stub_const(
        "#{described_class}::ENGINES",
        [Woods::Extractors::ViewEngines::Erb, fake_engine_class].freeze
      )
      expect(described_class.supported_template_engines).to eq(%i[erb fake])
    end

    it 'returns a frozen array' do
      expect(described_class.supported_template_engines).to be_frozen
    end
  end

  describe 'engine dispatch' do
    before do
      stub_const(
        "#{described_class}::ENGINES",
        [Woods::Extractors::ViewEngines::Erb, fake_engine_class].freeze
      )
    end

    it 'globs files for every registered engine' do
      create_file('app/views/home/index.html.erb', '<h1>Home</h1>')
      create_file('app/views/home/widget.fake', 'fake source')
      identifiers = described_class.new.extract_all.map(&:identifier)
      expect(identifiers).to contain_exactly('home/index.html.erb', 'home/widget.fake')
    end

    it 'routes each file to the matching engine based on extension' do
      create_file('app/views/home/widget.fake', 'fake source')
      units = described_class.new.extract_all
      expect(units.first.metadata[:template_engine]).to eq('fake')
    end

    it 'delegates scanning to the matched engine' do
      create_file('app/views/home/widget.fake', 'fake source')
      units = described_class.new.extract_all
      expect(units.first.metadata[:helpers_called]).to eq(['fake_helper'])
    end

    it 'returns nil from #extract_view_template_file for unregistered extensions' do
      unit = described_class.new.extract_view_template_file('/path/to/thing.unknown')
      expect(unit).to be_nil
    end
  end

  describe '#extract_all' do
    context 'when app/views/ does not exist' do
      it 'returns an empty array' do
        units = described_class.new.extract_all
        expect(units).to eq([])
      end
    end

    context 'when app/views/ is empty' do
      before { FileUtils.mkdir_p(File.join(tmp_dir, 'app/views')) }

      it 'returns an empty array' do
        units = described_class.new.extract_all
        expect(units).to eq([])
      end
    end

    context 'with ERB templates' do
      before do
        create_file('app/views/users/index.html.erb', users_index_content)
        create_file('app/views/users/show.html.erb', users_show_content)
        create_file('app/views/users/_user.html.erb', user_partial_content)
      end

      it 'returns one unit per template' do
        units = described_class.new.extract_all
        expect(units.size).to eq(3)
      end

      it 'produces units with type :view_template' do
        units = described_class.new.extract_all
        expect(units.map(&:type)).to all(eq(:view_template))
      end

      it 'uses relative path as identifier' do
        units = described_class.new.extract_all
        identifiers = units.map(&:identifier)
        expect(identifiers).to include('users/index.html.erb')
      end

      it 'sets namespace from directory structure' do
        units = described_class.new.extract_all
        index_unit = units.find { |u| u.identifier == 'users/index.html.erb' }
        expect(index_unit.namespace).to eq('users')
      end

      it 'detects template_engine as erb' do
        units = described_class.new.extract_all
        index_unit = units.find { |u| u.identifier == 'users/index.html.erb' }
        expect(index_unit.metadata[:template_engine]).to eq('erb')
      end

      it 'detects is_partial correctly' do
        units = described_class.new.extract_all
        partial = units.find { |u| u.identifier == 'users/_user.html.erb' }
        non_partial = units.find { |u| u.identifier == 'users/index.html.erb' }
        expect(partial.metadata[:is_partial]).to be true
        expect(non_partial.metadata[:is_partial]).to be false
      end

      it 'sets file_path to absolute path' do
        units = described_class.new.extract_all
        index_unit = units.find { |u| u.identifier == 'users/index.html.erb' }
        expect(index_unit.file_path).to end_with('app/views/users/index.html.erb')
      end

      it 'preserves source_code' do
        units = described_class.new.extract_all
        index_unit = units.find { |u| u.identifier == 'users/index.html.erb' }
        expect(index_unit.source_code).to include('<h1>Users</h1>')
      end
    end

    context 'with render calls' do
      before do
        create_file('app/views/posts/show.html.erb', render_content)
      end

      it 'extracts rendered partials' do
        units = described_class.new.extract_all
        unit = units.first
        expect(unit.metadata[:partials_rendered]).to include('comments/comment')
        expect(unit.metadata[:partials_rendered]).to include('shared/sidebar')
      end

      it 'creates dependencies for rendered partials' do
        units = described_class.new.extract_all
        deps = units.first.dependencies
        render_deps = deps.select { |d| d[:via] == :render }
        targets = render_deps.map { |d| d[:target] }
        expect(targets).to include('comments/_comment.html.erb')
        expect(targets).to include('shared/_sidebar.html.erb')
      end
    end

    context 'with instance variables' do
      before do
        create_file('app/views/articles/index.html.erb', ivar_content)
      end

      it 'extracts instance variables' do
        units = described_class.new.extract_all
        unit = units.first
        expect(unit.metadata[:instance_variables]).to contain_exactly('@articles', '@current_user')
      end
    end

    context 'with helper calls' do
      before do
        create_file('app/views/products/show.html.erb', helper_content)
      end

      it 'detects common Rails helpers' do
        units = described_class.new.extract_all
        unit = units.first
        expect(unit.metadata[:helpers_called]).to include('link_to')
        expect(unit.metadata[:helpers_called]).to include('image_tag')
        expect(unit.metadata[:helpers_called]).to include('number_to_currency')
      end
    end

    context 'with controller inference' do
      before do
        create_file('app/views/admin/users/index.html.erb', '<h1>Admin Users</h1>')
      end

      it 'infers controller from directory path' do
        units = described_class.new.extract_all
        deps = units.first.dependencies
        controller_dep = deps.find { |d| d[:via] == :view_render }
        expect(controller_dep[:target]).to eq('Admin::UsersController')
      end

      it 'sets namespace for nested directories' do
        units = described_class.new.extract_all
        expect(units.first.namespace).to eq('admin/users')
      end
    end

    context 'with non-ERB files mixed in' do
      before do
        create_file('app/views/home/index.html.erb', '<h1>Home</h1>')
        create_file('app/views/home/show.html.haml', '%h1 Show')
      end

      it 'only processes ERB files' do
        units = described_class.new.extract_all
        expect(units.size).to eq(1)
        expect(units.first.identifier).to eq('home/index.html.erb')
      end
    end

    context 'with empty template' do
      before do
        create_file('app/views/empty/index.html.erb', '')
      end

      it 'extracts the template with empty metadata' do
        units = described_class.new.extract_all
        unit = units.first
        expect(unit.metadata[:partials_rendered]).to eq([])
        expect(unit.metadata[:instance_variables]).to eq([])
        expect(unit.metadata[:helpers_called]).to eq([])
      end
    end

    context 'when file read fails' do
      before do
        create_file('app/views/broken/index.html.erb', 'content')
      end

      it 'skips the file and returns empty array' do
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(
          a_string_matching(%r{app/views/broken/index\.html\.erb})
        ).and_raise(Errno::EACCES)

        units = described_class.new.extract_all
        expect(units).to eq([])
      end
    end

    context 'with .erb files (no .html prefix)' do
      before do
        create_file('app/views/mailers/welcome.erb', '<p>Welcome!</p>')
      end

      it 'handles .erb files without .html prefix' do
        units = described_class.new.extract_all
        expect(units.size).to eq(1)
        expect(units.first.identifier).to eq('mailers/welcome.erb')
      end
    end

    context 'with render :symbol style' do
      before do
        create_file('app/views/orders/show.html.erb', <<~ERB)
          <h1>Order</h1>
          <%= render :header %>
        ERB
      end

      it 'extracts symbol-style render calls' do
        units = described_class.new.extract_all
        unit = units.first
        expect(unit.metadata[:partials_rendered]).to include('header')
      end
    end

    context 'with layouts directory' do
      before do
        create_file('app/views/layouts/application.html.erb', <<~ERB)
          <html>
          <body><%= yield %></body>
          </html>
        ERB
      end

      it 'does not infer controller for layout templates' do
        units = described_class.new.extract_all
        deps = units.first.dependencies
        controller_dep = deps.find { |d| d[:via] == :view_render }
        expect(controller_dep).to be_nil
      end
    end
  end

  # ── Navigation dependencies ──────────────────────────────────────────

  describe 'navigation dependencies' do
    let(:nav_extractor) do
      posts_route = double('Route',
                           defaults: { controller: 'posts', action: 'index' },
                           path: double(spec: double(to_s: '/posts(.:format)')),
                           verb: 'GET')
      users_route = double('Route',
                           defaults: { controller: 'users', action: 'index' },
                           path: double(spec: double(to_s: '/users(.:format)')),
                           verb: 'GET')
      named_routes = { posts: posts_route, users: users_route }
      routes_double = double('Routes', named_routes: named_routes)
      app_double = double('Application', routes: routes_double)
      stub_const('Rails', double('Rails', root: rails_root, logger: logger, application: app_double))
      described_class.new
    end

    before do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    it 'extracts link_to navigation edges via _path helpers' do
      create_file('app/views/home/index.html.erb', <<~ERB)
        <h1>Home</h1>
        <%= link_to "Posts", posts_path %>
      ERB

      units = nav_extractor.extract_all
      deps = units.first.dependencies
      nav_deps = deps.select { |d| d[:via] == :link_to }
      expect(nav_deps).to include(a_hash_including(target: 'PostsController'))
    end

    it 'extracts multiple navigation targets' do
      create_file('app/views/home/index.html.erb', <<~ERB)
        <%= link_to "Posts", posts_path %>
        <%= link_to "Users", users_path %>
      ERB

      units = nav_extractor.extract_all
      deps = units.first.dependencies
      nav_targets = deps.select { |d| d[:via] == :link_to }.map { |d| d[:target] }
      expect(nav_targets).to contain_exactly('PostsController', 'UsersController')
    end

    it 'returns no navigation edges when config is disabled' do
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)
      create_file('app/views/home/index.html.erb', '<%= link_to "Posts", posts_path %>')

      units = nav_extractor.extract_all
      deps = units.first.dependencies
      nav_deps = deps.select { |d| d[:via] == :link_to }
      expect(nav_deps).to be_empty
    end

    it 'skips unresolvable helpers' do
      create_file('app/views/home/index.html.erb', '<%= link_to "X", unknown_path %>')

      units = nav_extractor.extract_all
      deps = units.first.dependencies
      nav_deps = deps.select { |d| d[:via] == :link_to }
      expect(nav_deps).to be_empty
    end
  end

  # ── Form dependencies ──────────────────────────────────────────────

  describe 'form dependencies' do
    let(:form_extractor) do
      posts_route = double('Route',
                           defaults: { controller: 'posts', action: 'create' },
                           path: double(spec: double(to_s: '/posts(.:format)')),
                           verb: 'POST')
      named_routes = { posts: posts_route }
      routes_double = double('Routes', named_routes: named_routes)
      app_double = double('Application', routes: routes_double)
      stub_const('Rails', double('Rails', root: rails_root, logger: logger, application: app_double))
      described_class.new
    end

    before do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    it 'extracts form_with targeting a route helper' do
      create_file('app/views/posts/new.html.erb', <<~ERB)
        <%= form_with url: posts_path do |f| %>
          <%= f.text_field :title %>
          <%= f.submit %>
        <% end %>
      ERB

      units = form_extractor.extract_all
      deps = units.first.dependencies
      form_deps = deps.select { |d| d[:via] == :form_action }
      expect(form_deps).to include(a_hash_including(target: 'PostsController'))
    end

    it 'extracts form_for targeting a route helper' do
      create_file('app/views/posts/new.html.erb', <<~ERB)
        <%= form_for @post, url: posts_path do |f| %>
          <%= f.text_field :title %>
        <% end %>
      ERB

      units = form_extractor.extract_all
      deps = units.first.dependencies
      form_deps = deps.select { |d| d[:via] == :form_action }
      expect(form_deps).to include(a_hash_including(target: 'PostsController'))
    end

    it 'extracts multi-line form_with calls' do
      create_file('app/views/posts/new.html.erb', <<~ERB)
        <%= form_with model: @post,
                      url: posts_path do |f| %>
          <%= f.text_field :title %>
          <%= f.submit %>
        <% end %>
      ERB

      units = form_extractor.extract_all
      deps = units.first.dependencies
      form_deps = deps.select { |d| d[:via] == :form_action }
      expect(form_deps).to include(a_hash_including(target: 'PostsController'))
    end

    it 'returns no form edges when config is disabled' do
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)
      create_file('app/views/posts/new.html.erb', '<%= form_with url: posts_path do |f| %><% end %>')

      units = form_extractor.extract_all
      deps = units.first.dependencies
      form_deps = deps.select { |d| d[:via] == :form_action }
      expect(form_deps).to be_empty
    end
  end

  describe '#extract_view_template_file' do
    before do
      create_file('app/views/users/edit.html.erb', edit_content)
    end

    it 'extracts a single template file' do
      file_path = File.join(tmp_dir, 'app/views/users/edit.html.erb')
      unit = described_class.new.extract_view_template_file(file_path)
      expect(unit).to be_a(Woods::ExtractedUnit)
      expect(unit.identifier).to eq('users/edit.html.erb')
    end

    it 'returns nil for files no registered engine handles' do
      unit = described_class.new.extract_view_template_file('/fake/app/views/users/edit.html.haml')
      expect(unit).to be_nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Test Content
  # ──────────────────────────────────────────────────────────────────────

  def users_index_content
    <<~ERB
      <h1>Users</h1>
      <% @users.each do |user| %>
        <%= render partial: 'user', locals: { user: user } %>
      <% end %>
    ERB
  end

  def users_show_content
    <<~ERB
      <h1><%= @user.name %></h1>
      <p><%= @user.email %></p>
    ERB
  end

  def user_partial_content
    <<~ERB
      <div class="user">
        <span><%= user.name %></span>
        <%= link_to 'View', user_path(user) %>
      </div>
    ERB
  end

  def render_content
    <<~ERB
      <h1><%= @post.title %></h1>
      <%= render partial: 'comments/comment', collection: @comments %>
      <%= render 'shared/sidebar' %>
    ERB
  end

  def ivar_content
    <<~ERB
      <h1>Articles</h1>
      <% @articles.each do |article| %>
        <p><%= article.title %></p>
      <% end %>
      <p>Logged in as: <%= @current_user.name %></p>
    ERB
  end

  def helper_content
    <<~ERB
      <h1><%= @product.name %></h1>
      <%= link_to 'Back', products_path %>
      <%= image_tag @product.photo_url %>
      <p>Price: <%= number_to_currency @product.price %></p>
    ERB
  end

  def edit_content
    <<~ERB
      <h1>Edit User</h1>
      <%= form_for @user do |f| %>
        <%= f.text_field :name %>
        <%= f.submit %>
      <% end %>
    ERB
  end
end
