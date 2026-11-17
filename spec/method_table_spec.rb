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

  def facts(source)
    described_class.call(source).map { |entry| entry.values_at('name', 'kind', 'visibility') }
  end

  describe 'methods Ruby always defines private' do
    it 'keeps initialize, the copy hooks and respond_to_missing? private, even under a bare public' do
      source = <<~RUBY
        class Widget
          public
          def initialize; end
          def initialize_copy(other); end
          def initialize_dup(other); end
          def initialize_clone(other, freeze: nil); end
          def respond_to_missing?(name, include_all); end
          def call; end
        end
      RUBY
      expect(facts(source)).to eq([
                                    %w[initialize instance private],
                                    %w[initialize_copy instance private],
                                    %w[initialize_dup instance private],
                                    %w[initialize_clone instance private],
                                    %w[respond_to_missing? instance private],
                                    %w[call instance public]
                                  ])
    end

    it 'follows a later explicit visibility call, as Ruby does' do
      source = "class Widget\n  def initialize; end\n  public :initialize\n  " \
               "public def initialize_copy(other); end\nend\n"
      expect(facts(source)).to eq([%w[initialize instance public], %w[initialize_copy instance public]])
    end

    it 'does not apply to singleton definitions, but does to a class_methods block' do
      source = <<~RUBY
        module Sized
          def self.initialize; end
          class << self
            def respond_to_missing?(name, include_all); end
          end
          class_methods do
            def initialize; end
          end
          module_function
          def initialize_dup(other); end
        end
      RUBY
      expect(facts(source)).to eq([
                                    %w[initialize singleton public],
                                    %w[respond_to_missing? singleton public],
                                    %w[initialize singleton private],
                                    %w[initialize_dup module_function public]
                                  ])
    end
  end

  describe 'module_function' do
    it 'makes the named methods module functions in every argument form' do
      source = <<~RUBY
        module Util
          def a; end
          def b; end
          def c; end
          def d; end
          module_function :a
          module_function :b, 'c'
          module_function def e; end
          module_function
          def f; end
          private
          def g; end
        end
      RUBY
      expect(facts(source)).to eq([
                                    %w[a module_function public],
                                    %w[b module_function public],
                                    %w[c module_function public],
                                    %w[d instance public],
                                    %w[e module_function public],
                                    %w[f module_function public],
                                    %w[g instance private]
                                  ])
    end

    it 'makes a private instance method a module function, and ignores a name defined later' do
      source = "module Util\n  private def a; end\n  module_function :a, :later\n  def later; end\nend\n"
      expect(facts(source)).to eq([%w[a module_function public], %w[later instance public]])
    end

    it 'splits a module function whose instance side a later call makes public or protected' do
      source = <<~RUBY
        module Util
          module_function
          def a; end
          def b; end
          def c; end
          public :a
          protected :b
          private :c
        end
      RUBY
      expect(facts(source)).to eq([
                                    %w[a instance public], %w[a singleton public],
                                    %w[b instance protected], %w[b singleton public],
                                    %w[c module_function public]
                                  ])
    end
  end

  describe 'private_class_method and public_class_method' do
    it 'set the singleton visibility in every argument form' do
      source = <<~RUBY
        class Report
          private_class_method def self.a; end
          def self.b; end
          def self.c; end
          def self.d; end
          private_class_method :b, 'c'
          private_class_method [:d]
          public_class_method :d
          public_class_method def self.e; end
          def b; end
        end
      RUBY
      expect(facts(source)).to eq([
                                    %w[a singleton private],
                                    %w[b singleton private],
                                    %w[c singleton private],
                                    %w[d singleton public],
                                    %w[e singleton public],
                                    %w[b instance public]
                                  ])
    end

    it 'sets the singleton side of a module function' do
      source = "module Util\n  module_function\n  def a; end\n  def b; end\n  private_class_method :a\n  " \
               "class << self\n    private :b\n  end\nend\n"
      expect(facts(source)).to eq([%w[a module_function private], %w[b module_function private]])
    end
  end

  it 'applies private, protected and public with symbol, string and array arguments' do
    source = <<~RUBY
      class Account
        def a; end
        def b; end
        def c; end
        def d; end
        private :a, 'b'
        protected [:c]
        private attr_reader :e
        private :d
        public :d
        class << self
          def f; end
          private :f
        end
      end
    RUBY
    expect(facts(source)).to eq([
                                  %w[a instance private],
                                  %w[b instance private],
                                  %w[c instance protected],
                                  %w[d instance public],
                                  %w[f singleton private]
                                ])
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

  describe 'definitions Ruby runs only on one path' do
    def candidates(source)
      described_class.call(source).map { |entry| entry.values_at('name', 'kind', 'owner', 'candidate') }
    end

    def candidates_by_line(source)
      described_class.call(source).map { |entry| entry.values_at('name', 'line', 'candidate') }
    end

    it 'lists a definition under if, unless, elsif, else or a modifier as a conditional candidate' do
      source = <<~RUBY
        class Post
          def plain; end
          if Feature.on?
            def a; end
          elsif Feature.half?
            def b; end
          else
            def c; end
          end
          unless Feature.on?
            def d; end
          else
            def e; end
          end
          def f; end if Feature.on?
        end
      RUBY

      expect(candidates(source)).to eq([
                                         ['plain', 'instance', 'Post', nil], %w[a instance Post conditional],
                                         %w[b instance Post conditional],
                                         %w[c instance Post conditional],
                                         %w[d instance Post conditional],
                                         %w[e instance Post conditional],
                                         %w[f instance Post conditional]
                                       ])
    end

    it 'reads a begin body and its ensure as run, and its rescue and else as conditional' do
      source = <<~RUBY
        class Post
          begin
            def a; end
          rescue LoadError
            def b; end
          else
            def c; end
          ensure
            def d; end
          end
        end
      RUBY

      expect(candidates(source)).to eq([
                                         ['a', 'instance', 'Post', nil], %w[b instance Post conditional],
                                         %w[c instance Post conditional], ['d', 'instance', 'Post', nil]
                                       ])
    end

    it 'lists a definition in a when, in or else branch of a case as a conditional candidate' do
      source = <<~RUBY
        class Post
          case FLAG
          when 1 then def a; end
          else def b; end
          end
          case FLAG
          in Integer then def c; end
          end
        end
      RUBY

      expect(candidates(source)).to eq([%w[a instance Post conditional], %w[b instance Post conditional],
                                        %w[c instance Post conditional]])
    end

    it 'keeps both alternatives of a conditional, and the definite definition beside a later candidate' do
      source = <<~RUBY
        class Post
          def a; end
          if RUBY_VERSION >= '3'
            def a; end
          else
            def a; end
          end
          if Feature.on?
            def b; end
          end
          def b; end
        end
      RUBY

      expect(table(source).map { |name, _, line| [name, line] }).to eq([['a', 2], ['a', 4], ['a', 6], ['b', 11]])
    end

    # Whenever the later `def` runs, Ruby has run the earlier one first.
    it 'replaces a candidate that a later definition in the same branch, or in an enclosing one, overwrites' do
      source = <<~RUBY
        class Post
          if Feature.on?
            def a; :old; end
            def a; :new; end
            if Feature.beta?
              def x; end
            end
            def x; end
          end
          included do
            def y; end
            def y; end
          end
        end
      RUBY

      expect(candidates_by_line(source)).to eq([['a', 4, 'conditional'], ['x', 8, 'conditional'], ['y', 12, 'block']])
    end

    # A nested branch may not run, and a sibling branch runs instead.
    it 'keeps a candidate beside a later one in a nested or a sibling branch' do
      source = <<~RUBY
        class Post
          if Feature.on?
            def x; end
            if Feature.beta?
              def x; end
            end
          else
            def x; end
          end
        end
      RUBY

      expect(candidates_by_line(source)).to eq([['x', 3, 'conditional'], ['x', 5, 'conditional'],
                                                ['x', 8, 'conditional']])
    end

    it 'leaves a visibility section inside a branch to that branch' do
      source = <<~RUBY
        class Post
          if Feature.on?
            private
            def a; end
          end
          def b; end
        end
      RUBY

      expect(table(source).map { |name, _, _, _, visibility| [name, visibility] }).to eq([%w[a private], %w[b public]])
    end

    it 'applies a visibility call in a branch to the candidates of that branch only' do
      source = <<~RUBY
        class Post
          if Feature.on?
            def x; end
          else
            private def x; end
          end
          if Feature.on?
            def y; end
          end
          case Feature.mode
          when :a then def y; end
          else
            def y; end
            if Feature.strict?
              protected :y
            end
          end
        end
      RUBY

      expect(table(source).map { |name, _, line, _, visibility| [name, line, visibility] }).to eq(
        [['x', 3, 'public'], ['x', 5, 'private'], ['y', 8, 'public'], ['y', 11, 'public'], ['y', 13, 'protected']]
      )
    end

    it 'makes every alternative of a name a module function, and keeps candidates beside a definite source' do
      source = <<~RUBY
        module Util
          if Feature.on?
            def x; end
          else
            def x; end
          end
          def y; end
          if Feature.on?
            def y; end
          end
          module_function :x, :y
        end
      RUBY

      expect(described_class.call(source).map { |entry| entry.values_at('name', 'kind', 'line', 'candidate') })
        .to eq([['x', 'module_function', 3, 'conditional'], ['x', 'module_function', 5, 'conditional'],
                ['y', 'module_function', 7, nil],
                ['y', 'module_function', 9, 'conditional']])
    end

    it 'lists a definition in a block of the class body as a block candidate of the lexical owner' do
      source = <<~RUBY
        class Plugin
          Registry.create do
            def run; end
          end
          class_methods do
            def build; end
          end
        end
      RUBY

      expect(candidates(source)).to eq([%w[run instance Plugin block], ['build', 'singleton', 'Plugin', nil]])
    end

    it 'lists a definition passed to a method that is not a visibility call as run' do
      source = "class Post\n  memoize def total; end\n  private\n  cache def hidden; end\nend\n"

      expect(table(source).map { |name, kind, _, _, visibility| [name, kind, visibility] })
        .to eq([%w[total instance public], %w[hidden instance private]])
    end

    # A decorator returns the name its `def` returns, so the visibility call
    # receives that name.
    it 'gives a definition inside a wrapper passed to a visibility call the visibility the call names' do
      source = <<~RUBY
        module Util
          private memoize def total; end
          private memoize cache def deep; end
          module_function cache def tool; end
          private_class_method memoize def self.build; end
          protected
          public(memoize(def shown; end))
        end
      RUBY

      expect(table(source).map { |name, kind, _, _, visibility| [name, kind, visibility] })
        .to eq([%w[total instance private], %w[deep instance private], %w[tool module_function public],
                %w[build singleton private], %w[shown instance public]])
    end
  end
end
