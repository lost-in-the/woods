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
end
