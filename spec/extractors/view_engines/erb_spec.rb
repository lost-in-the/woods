# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/view_engines/erb'

RSpec.describe Woods::Extractors::ViewEngines::Erb do
  subject(:engine) { described_class.new }

  describe '::EXTENSIONS' do
    it 'lists both .html.erb and .erb' do
      expect(described_class::EXTENSIONS).to eq(%w[.html.erb .erb])
    end

    it 'orders longer suffix first so dispatch can match greedily' do
      expect(described_class::EXTENSIONS.first).to eq('.html.erb')
    end
  end

  describe '::ENGINE_NAME' do
    it 'is :erb' do
      expect(described_class::ENGINE_NAME).to eq(:erb)
    end
  end

  describe '#handles?' do
    it 'matches .html.erb' do
      expect(engine.handles?('app/views/users/index.html.erb')).to be true
    end

    it 'matches bare .erb' do
      expect(engine.handles?('app/views/mailers/welcome.erb')).to be true
    end

    it 'rejects .haml' do
      expect(engine.handles?('app/views/users/show.html.haml')).to be false
    end

    it 'rejects .slim' do
      expect(engine.handles?('app/views/users/show.html.slim')).to be false
    end
  end

  describe '#scan_partials' do
    it 'extracts render partial: "path" form' do
      source = "<%= render partial: 'comments/comment' %>"
      expect(engine.scan_partials(source)).to eq(['comments/comment'])
    end

    it 'extracts bare render "path" form' do
      source = "<%= render 'shared/sidebar' %>"
      expect(engine.scan_partials(source)).to eq(['shared/sidebar'])
    end

    it 'extracts render :symbol form' do
      source = '<%= render :header %>'
      expect(engine.scan_partials(source)).to eq(['header'])
    end

    it 'handles all three forms in the same template without duplicates' do
      source = <<~ERB
        <%= render partial: 'comments/comment' %>
        <%= render 'shared/sidebar' %>
        <%= render :header %>
        <%= render 'shared/sidebar' %>
      ERB
      expect(engine.scan_partials(source)).to contain_exactly(
        'comments/comment', 'shared/sidebar', 'header'
      )
    end

    it 'returns an empty array for source with no render calls' do
      expect(engine.scan_partials('<h1>No renders</h1>')).to eq([])
    end
  end

  describe '#scan_instance_variables' do
    it 'extracts @ivars in sorted order' do
      source = '<p><%= @user.name %> <%= @articles.count %> <%= @user.email %></p>'
      expect(engine.scan_instance_variables(source)).to eq(%w[@articles @user])
    end

    it 'deduplicates repeated ivars' do
      source = '<%= @a %> <%= @a %>'
      expect(engine.scan_instance_variables(source)).to eq(['@a'])
    end

    it 'returns an empty array when no ivars are present' do
      expect(engine.scan_instance_variables('<h1>static</h1>')).to eq([])
    end
  end

  describe '#scan_helpers' do
    it 'detects common Rails helpers' do
      source = <<~ERB
        <%= link_to 'X', path %>
        <%= image_tag photo %>
        <%= number_to_currency price %>
      ERB
      expect(engine.scan_helpers(source)).to include('link_to', 'image_tag', 'number_to_currency')
    end

    it 'uses word boundaries to avoid false positives inside other identifiers' do
      # `my_link_to_thing` contains "link_to" but shouldn't match as a helper
      source = '<%= my_link_to_thing %>'
      expect(engine.scan_helpers(source)).not_to include('link_to')
    end

    it 'returns results sorted' do
      source = '<%= link_to %> <%= image_tag %> <%= button_to %>'
      result = engine.scan_helpers(source)
      expect(result).to eq(result.sort)
    end
  end

  describe '#resolve_partial_identifier' do
    it 'resolves namespaced partial paths to their file identifier' do
      result = engine.resolve_partial_identifier('comments/comment', 'posts/show.html.erb')
      expect(result).to eq('comments/_comment.html.erb')
    end

    it 'resolves bare partial names relative to the current template directory' do
      result = engine.resolve_partial_identifier('comment', 'posts/show.html.erb')
      expect(result).to eq('posts/_comment.html.erb')
    end

    it 'handles bare partials in the root view directory' do
      result = engine.resolve_partial_identifier('sidebar', 'index.html.erb')
      expect(result).to eq('_sidebar.html.erb')
    end
  end
end
