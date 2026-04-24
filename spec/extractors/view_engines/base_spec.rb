# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/view_engines/base'

RSpec.describe Woods::Extractors::ViewEngines::Base do
  subject(:engine) { described_class.new }

  describe 'abstract methods' do
    # A representative check — the other abstract methods share the
    # same `raise NotImplementedError, "#{self.class.name} ..."` shape.
    # Exhaustively testing each is tautology (verifying that `raise`
    # raises). What's worth asserting is that the error message names
    # the concrete subclass, since that's the bit future engine authors
    # rely on when they forget to override a method.
    it 'names the concrete subclass in the NotImplementedError message' do
      subclass = Class.new(described_class)
      stub_const('FakeHamlEngine', subclass)
      expect { subclass.new.name }.to raise_error(NotImplementedError, /FakeHamlEngine/)
    end
  end

  describe '#handles?' do
    let(:haml_like_class) do
      Class.new(described_class) do
        def extensions
          %w[.html.haml .haml]
        end
      end
    end
    let(:haml_like_engine) { haml_like_class.new }

    it 'returns true when a known extension suffix-matches the path' do
      expect(haml_like_engine.handles?('app/views/users/index.html.haml')).to be true
    end

    it 'returns true for the shorter extension too' do
      expect(haml_like_engine.handles?('mailer.haml')).to be true
    end

    it 'returns false when no extension matches' do
      expect(haml_like_engine.handles?('app/views/users/index.html.erb')).to be false
    end

    it 'propagates NotImplementedError from #extensions when not overridden' do
      expect { engine.handles?('foo.erb') }.to raise_error(NotImplementedError, /#extensions/)
    end
  end

  describe '#parse' do
    it 'returns the source unchanged by default (identity hook)' do
      expect(engine.parse('<h1>hello</h1>')).to eq('<h1>hello</h1>')
    end

    it 'is overridable so engines with expensive parsing can memoize an IR' do
      subclass = Class.new(described_class) do
        def parse(source)
          { ir: :compiled, from: source }
        end
      end
      expect(subclass.new.parse('src')).to eq(ir: :compiled, from: 'src')
    end
  end
end
