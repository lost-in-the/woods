# frozen_string_literal: true

require 'spec_helper'
require 'woods/gem_mapper'

RSpec.describe 'Static map lexical qualification' do
  it 'resolves nested includes without inventing scopes for qualified declarations' do
    source = <<~RUBY_SOURCE
      module Outer
        module Shared; end
        module Inner
          class Nested
            include Shared
          end
        end
      end
      module Shared; end
      class Outer::Inner::Qualified
        include Shared
      end
    RUBY_SOURCE
    _units, graph = Woods::GemMapSource.new(root: Pathname.new(Dir.pwd)).build(File.join(Dir.pwd,
                                                                                         'lib/example.rb') => source)
    expect(graph.dependents_of('Outer::Shared')).to include('Outer::Inner::Nested')
    expect(graph.dependents_of('Outer::Shared')).not_to include('Outer::Inner::Qualified')
    expect(graph.dependents_of('Shared')).to include('Outer::Inner::Qualified')
  end
  it 'resolves constants a method calls through the lexical scopes of its definition' do
    source = <<~RUBY_SOURCE
      module Outer
        module Extraction
          class Capture; def self.build; end; end
        end
        class Runner
          def run
            Extraction::Capture.build
          end
        end
      end
      class Outer::Compact
        def run
          Extraction::Capture.build
        end
      end
    RUBY_SOURCE
    path = File.join(Dir.pwd, 'lib/example.rb')
    _units, graph = Woods::GemMapSource.new(root: Pathname.new(Dir.pwd)).build(path => source)

    expect(graph.dependents_of('Outer::Extraction::Capture')).to include('Outer::Runner#run')
    # A compact `class Outer::Compact` does not open Outer, so Ruby would not
    # find Extraction there either; the map must not invent that scope.
    expect(graph.dependents_of('Outer::Extraction::Capture')).not_to include('Outer::Compact#run')
  end

  [true, false].each do |use_prism|
    it "preserves absolute references and declarations with Prism=#{use_prism}" do
      allow_any_instance_of(Woods::Ast::Parser).to receive(:prism_available?).and_return(use_prism)
      source = <<~RUBY_SOURCE
        class Base; end
        module Shared; end
        module Outer
          class Base; end
          module Shared; end
          class Child < ::Base
            include ::Shared
          end
          class ::Absolute
            class Nested; def call; end; end
          end
        end
      RUBY_SOURCE
      path = File.join(Dir.pwd, 'lib/example.rb')
      units, graph = Woods::GemMapSource.new(root: Pathname.new(Dir.pwd)).build(path => source)
      expect(graph.dependencies_of('Outer::Child')).to include('Base', 'Shared')
      expect(graph.dependencies_of('Outer::Child')).not_to include('Outer::Base', 'Outer::Shared')
      expect(units.map(&:identifier)).to include('Absolute', 'Absolute::Nested', 'Absolute::Nested#call')
    end
  end
end
