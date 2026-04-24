# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/view_engines/base'

RSpec.describe Woods::Extractors::ViewEngines::Base do
  subject(:engine) { described_class.new }

  describe 'abstract contract' do
    it 'requires #name' do
      expect { engine.name }.to raise_error(NotImplementedError, /#name/)
    end

    it 'requires #extensions' do
      expect { engine.extensions }.to raise_error(NotImplementedError, /#extensions/)
    end

    it 'requires #scan_partials' do
      expect { engine.scan_partials('src') }.to raise_error(NotImplementedError, /#scan_partials/)
    end

    it 'requires #scan_instance_variables' do
      expect { engine.scan_instance_variables('src') }
        .to raise_error(NotImplementedError, /#scan_instance_variables/)
    end

    it 'requires #scan_helpers' do
      expect { engine.scan_helpers('src') }.to raise_error(NotImplementedError, /#scan_helpers/)
    end

    it 'requires #resolve_partial_identifier' do
      expect { engine.resolve_partial_identifier('p', 'i') }
        .to raise_error(NotImplementedError, /#resolve_partial_identifier/)
    end

    it 'names the concrete subclass in the error message' do
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
end
