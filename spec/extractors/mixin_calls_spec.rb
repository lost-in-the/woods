# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/mixin_calls'

RSpec.describe Woods::Extractors::MixinCalls do
  def calls(source, kinds = %i[include extend prepend])
    described_class.call(source, kinds)
  end

  it 'reads every constant argument of include, extend and prepend calls, in source order' do
    source = <<~RUBY
      module Stackable
        include Alpha, Beta
        include(Gamma)
        include ::Depot::Weighable
        extend Depot::Countable
        prepend Wrapping
        include Delta,
                Epsilon::Zeta
        included do
          include Inner
        end
        def self.included(base)
          base.extend ClassMethods
        end
      end
    RUBY
    expect(calls(source)).to eq(
      [[:include, 'Alpha'], [:include, 'Beta'], [:include, 'Gamma'], [:include, '::Depot::Weighable'],
       [:extend, 'Depot::Countable'], [:prepend, 'Wrapping'], [:include, 'Delta'], [:include, 'Epsilon::Zeta'],
       [:include, 'Inner'], [:extend, 'ClassMethods']]
    )
  end

  it 'ignores comments, strings, heredocs, method names and non-constant arguments' do
    source = <<~'RUBY'
      module Stackable
        # The include of this module is optional; extend Later if needed.
        NOTE = "include Quoted"
        DOC = <<~TEXT
          prepend Heredoc
        TEXT
        def include_of(other); end
        def includes; :include; end
        extend self
        include helper_module
        include "#{Interp}"
      end
    RUBY
    expect(calls(source)).to eq([])
  end

  it 'ignores a =begin block' do
    expect(calls("module M\n=begin\ninclude Hidden\n=end\n  include Shown\nend\n")).to eq([[:include, 'Shown']])
  end

  it 'filters by kind' do
    expect(calls("module M\n  include A\n  extend B\nend\n", [:extend])).to eq([[:extend, 'B']])
  end
end
