# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/method_table'

RSpec.describe Woods::MethodTable do
  def table(source)
    described_class.call(source).map do |entry|
      entry.values_at('name', 'kind', 'line', 'end_line', 'visibility', 'owner')
    end
  end

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

  it 'lists definitions with their line ranges, kinds and qualified owners' do
    source = <<~RUBY
      module Admin
        class Post < ApplicationRecord
          def self.recent
            order(:id)
          end

          def title; end

          class << self
            def build; end
          end

          class Draft
            def save; end
          end
        end
      end
    RUBY
    expect(table(source)).to eq([
                                  ['recent', 'singleton', 3, 5, 'public', 'Admin::Post'],
                                  ['title', 'instance', 7, 7, 'public', 'Admin::Post'],
                                  ['build', 'singleton', 10, 10, 'public', 'Admin::Post'],
                                  ['save', 'instance', 14, 14, 'public', 'Admin::Post::Draft']
                                ])
  end

  it 'follows the literal visibility forms of the body' do
    source = <<~RUBY
      class Post
        def shown; end
        private def slug; end
        protected
        def guard; end
        public
        def later; end
        private :later
        def self.helper; end
        private_class_method :helper
        private
        def hidden; end
        class << self
          private
          def secret; end
        end
      end
    RUBY
    expect(table(source).map { |name, kind, *, visibility, _| [name, kind, visibility] }).to eq([
                                                                                                  %w[shown instance
                                                                                                     public],
                                                                                                  %w[slug instance
                                                                                                     private],
                                                                                                  %w[guard instance
                                                                                                     protected],
                                                                                                  %w[later instance
                                                                                                     private],
                                                                                                  %w[helper singleton
                                                                                                     private],
                                                                                                  %w[hidden instance
                                                                                                     private],
                                                                                                  %w[secret singleton
                                                                                                     private]
                                                                                                ])
  end

  it 'owns inlined concern methods by the concern, at their lines in the display block' do
    concern = "module Taggable\n  extend ActiveSupport::Concern\n  class_methods do\n    " \
              "def tagged(name); end\n  end\n\n  def tag_list\n    tags.map(&:name)\n  end\nend\n"
    source = "class Post < ApplicationRecord\n\n#{concern_block('Taggable', concern)}\n  def title; end\nend\n"
    expect(table(source)).to eq([
                                  ['tagged', 'singleton', 9, 9, 'public', 'Taggable'],
                                  ['tag_list', 'instance', 12, 14, 'public', 'Taggable'],
                                  ['title', 'instance', 18, 18, 'public', 'Post']
                                ])
    expect(source.lines[11]).to include('def tag_list')
  end

  it 'records module_function definitions and ignores definitions on other receivers' do
    source = "module Util\n  module_function\n  def call; end\n  def other.thing; end\nend\n"
    expect(table(source)).to eq([['call', 'module_function', 3, 3, 'public', 'Util']])
  end

  it 'keeps no table for source that does not parse, and an empty one for a body without methods' do
    expect(described_class.call("class Post\n  def broken(\nend\n")).to be_nil
    expect(described_class.call("class Post < ApplicationRecord\nend\n")).to eq([])
    expect(described_class.call(nil)).to be_nil
  end

  it 'records the table on class-based units only, leaving others unchanged' do
    model = Woods::ExtractedUnit.new(type: :model, identifier: 'Post', file_path: 'app/models/post.rb')
    model.source_code = "class Post\n  def title; end\nend\n"
    described_class.record(model)
    expect(model.metadata[:methods].map { |entry| entry['name'] }).to eq(['title'])

    route = Woods::ExtractedUnit.new(type: :route, identifier: 'GET /posts', file_path: nil)
    route.source_code = "class X\n  def y; end\nend\n"
    described_class.record(route)
    expect(route.metadata).not_to have_key(:methods)
  end
end
