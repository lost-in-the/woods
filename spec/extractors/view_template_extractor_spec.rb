# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/view_template_extractor'

RSpec.describe CodebaseIndex::Extractors::ViewTemplateExtractor do
  include_context 'extractor setup'

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

  describe '#extract_view_template_file' do
    before do
      create_file('app/views/users/edit.html.erb', edit_content)
    end

    it 'extracts a single template file' do
      file_path = File.join(tmp_dir, 'app/views/users/edit.html.erb')
      unit = described_class.new.extract_view_template_file(file_path)
      expect(unit).to be_a(CodebaseIndex::ExtractedUnit)
      expect(unit.identifier).to eq('users/edit.html.erb')
    end

    it 'returns nil for non-ERB files' do
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
