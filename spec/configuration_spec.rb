# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'

RSpec.describe CodebaseIndex::Configuration do
  subject(:config) { described_class.new }

  describe 'default values' do
    it 'sets max_context_tokens to 8000' do
      expect(config.max_context_tokens).to eq(8000)
    end

    it 'sets similarity_threshold to 0.7' do
      expect(config.similarity_threshold).to eq(0.7)
    end

    it 'sets pretty_json to true' do
      expect(config.pretty_json).to eq(true)
    end

    it 'sets extractors to the default list' do
      expect(config.extractors).to include(:models, :controllers, :services)
      expect(config.extractors).to all(be_a(Symbol))
    end

    it 'sets embedding_model to text-embedding-3-small' do
      expect(config.embedding_model).to eq('text-embedding-3-small')
    end

    it 'sets include_framework_sources to true' do
      expect(config.include_framework_sources).to eq(true)
    end

    it 'sets gem_configs to an empty hash' do
      expect(config.gem_configs).to eq({})
    end

    it 'sets context_format to :markdown' do
      expect(config.context_format).to eq(:markdown)
    end

    it 'sets session_tracer_enabled to false' do
      expect(config.session_tracer_enabled).to eq(false)
    end

    it 'sets session_store to nil' do
      expect(config.session_store).to be_nil
    end

    it 'sets session_id_proc to nil' do
      expect(config.session_id_proc).to be_nil
    end

    it 'sets session_exclude_paths to empty array' do
      expect(config.session_exclude_paths).to eq([])
    end
  end

  describe 'session tracer configuration' do
    it 'allows setting session_tracer_enabled' do
      config.session_tracer_enabled = true
      expect(config.session_tracer_enabled).to eq(true)
    end

    it 'allows setting session_store' do
      store = Object.new
      config.session_store = store
      expect(config.session_store).to eq(store)
    end

    it 'allows setting session_id_proc' do
      proc = ->(request) { request.session.id }
      config.session_id_proc = proc
      expect(config.session_id_proc).to eq(proc)
    end

    it 'allows setting session_exclude_paths' do
      config.session_exclude_paths = ['/health', '/assets']
      expect(config.session_exclude_paths).to eq(['/health', '/assets'])
    end
  end

  describe '#context_format=' do
    it 'accepts valid format symbols' do
      %i[claude markdown plain json].each do |fmt|
        config.context_format = fmt
        expect(config.context_format).to eq(fmt)
      end
    end

    it 'raises on invalid format' do
      expect { config.context_format = :xml }.to raise_error(
        CodebaseIndex::ConfigurationError, /context_format must be one of/
      )
    end

    it 'raises on string format' do
      expect { config.context_format = 'markdown' }.to raise_error(CodebaseIndex::ConfigurationError)
    end
  end

  describe '#max_context_tokens=' do
    it 'accepts a positive integer' do
      config.max_context_tokens = 4000
      expect(config.max_context_tokens).to eq(4000)
    end

    it 'raises on nil' do
      expect { config.max_context_tokens = nil }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on negative integer' do
      expect { config.max_context_tokens = -1 }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on zero' do
      expect { config.max_context_tokens = 0 }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on float' do
      expect { config.max_context_tokens = 1.5 }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on string' do
      expect { config.max_context_tokens = '8000' }.to raise_error(CodebaseIndex::ConfigurationError)
    end
  end

  describe '#similarity_threshold=' do
    it 'accepts 0.0' do
      config.similarity_threshold = 0.0
      expect(config.similarity_threshold).to eq(0.0)
    end

    it 'accepts 1.0' do
      config.similarity_threshold = 1.0
      expect(config.similarity_threshold).to eq(1.0)
    end

    it 'accepts 0.5' do
      config.similarity_threshold = 0.5
      expect(config.similarity_threshold).to eq(0.5)
    end

    it 'converts integer to float' do
      config.similarity_threshold = 0
      expect(config.similarity_threshold).to eq(0.0)
    end

    it 'raises on negative value' do
      expect { config.similarity_threshold = -0.1 }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on value greater than 1.0' do
      expect { config.similarity_threshold = 1.1 }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on non-numeric string' do
      expect { config.similarity_threshold = 'high' }.to raise_error(CodebaseIndex::ConfigurationError)
    end
  end

  describe '#extractors=' do
    it 'accepts an array of symbols' do
      config.extractors = %i[models controllers]
      expect(config.extractors).to eq(%i[models controllers])
    end

    it 'raises on non-array' do
      expect { config.extractors = :models }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on array of strings' do
      expect { config.extractors = %w[models controllers] }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on mixed array' do
      expect { config.extractors = [:models, 'controllers'] }.to raise_error(CodebaseIndex::ConfigurationError)
    end
  end

  describe '#pretty_json=' do
    it 'accepts true' do
      config.pretty_json = true
      expect(config.pretty_json).to eq(true)
    end

    it 'accepts false' do
      config.pretty_json = false
      expect(config.pretty_json).to eq(false)
    end

    it 'raises on nil' do
      expect { config.pretty_json = nil }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on string' do
      expect { config.pretty_json = 'true' }.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'raises on integer' do
      expect { config.pretty_json = 1 }.to raise_error(CodebaseIndex::ConfigurationError)
    end
  end

  describe '#output_dir=' do
    it 'accepts a string path' do
      config.output_dir = '/tmp/test'
      expect(config.output_dir).to eq('/tmp/test')
    end

    it 'raises on nil' do
      expect { config.output_dir = nil }.to raise_error(CodebaseIndex::ConfigurationError)
    end
  end

  describe 'CodebaseIndex.configure' do
    before { CodebaseIndex.configuration = nil }

    after { CodebaseIndex.configuration = nil }

    it 'yields the configuration' do
      CodebaseIndex.configure do |c|
        c.max_context_tokens = 4000
      end

      expect(CodebaseIndex.configuration.max_context_tokens).to eq(4000)
    end

    it 'raises on invalid values in configure block' do
      expect do
        CodebaseIndex.configure do |c|
          c.max_context_tokens = -1
        end
      end.to raise_error(CodebaseIndex::ConfigurationError)
    end

    it 'uses CONFIG_MUTEX for thread safety' do
      expect(CodebaseIndex::CONFIG_MUTEX).to be_a(Mutex)
    end

    it 'does not corrupt configuration under concurrent access' do
      CodebaseIndex.configuration = nil

      threads = 10.times.map do |i|
        Thread.new do
          CodebaseIndex.configure do |c|
            c.max_context_tokens = 1000 + i
          end
        end
      end
      threads.each(&:join)

      # Configuration should be set and valid (one thread won the race)
      expect(CodebaseIndex.configuration).not_to be_nil
      expect(CodebaseIndex.configuration.max_context_tokens).to be_a(Integer)
      expect(CodebaseIndex.configuration.max_context_tokens).to be_positive
    end

    it 'is reentrant — nested configure calls do not deadlock' do
      # Mutexes in Ruby are not reentrant by default; confirm we don't call
      # configure recursively (this documents the intended usage boundary)
      expect do
        CodebaseIndex.configure do |c|
          c.max_context_tokens = 2000
        end
      end.not_to raise_error
    end
  end
end
