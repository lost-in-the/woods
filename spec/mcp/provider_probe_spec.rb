# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/errors'
require 'woods/mcp/provider_probe'
require 'woods/embedding/provider'
require 'woods/embedding/openai'

RSpec.describe Woods::MCP::ProviderProbe do
  let(:ollama_provider) do
    Woods::Embedding::Provider::Ollama.new(
      host: 'http://ollama.internal:11434',
      model: 'nomic-embed-text'
    )
  end

  let(:openai_provider) do
    Woods::Embedding::Provider::OpenAI.new(api_key: 'sk-test')
  end

  # Stubs Net::HTTP#start to yield a mock that returns +response+ from #get.
  def stub_net_http(host, port, response)
    http_double = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).with(host, port).and_return(http_double)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:start).and_yield(http_double)
    allow(http_double).to receive(:get).and_return(response)
    http_double
  end

  # Stubs Net::HTTP#start to raise +error+ when called.
  def stub_net_http_raise(host, port, error)
    http_double = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).with(host, port).and_return(http_double)
    allow(http_double).to receive(:open_timeout=)
    allow(http_double).to receive(:read_timeout=)
    allow(http_double).to receive(:use_ssl=)
    allow(http_double).to receive(:start).and_raise(error)
    http_double
  end

  describe '.reachable!' do
    # --- Ollama ---

    context 'when Ollama responds with 200' do
      it 'returns the provider unchanged' do
        response = instance_double(Net::HTTPOK)
        allow(response).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
        stub_net_http('ollama.internal', 11_434, response)

        result = described_class.reachable!(ollama_provider)
        expect(result).to be(ollama_provider)
      end

      it 'probes GET /api/tags on the configured Ollama host' do
        response = instance_double(Net::HTTPOK)
        allow(response).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
        http_double = stub_net_http('ollama.internal', 11_434, response)

        described_class.reachable!(ollama_provider)
        expect(http_double).to have_received(:get).with('/api/tags')
      end

      it 'treats non-5xx responses (e.g. 404) as reachable' do
        response = instance_double(Net::HTTPNotFound)
        allow(response).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
        stub_net_http('ollama.internal', 11_434, response)

        expect { described_class.reachable!(ollama_provider) }.not_to raise_error
      end
    end

    context 'when Ollama connection is refused' do
      it 'raises ProviderUnreachable with url and reason: "connection_refused"' do
        stub_net_http_raise('ollama.internal', 11_434, Errno::ECONNREFUSED)

        expect { described_class.reachable!(ollama_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.url).to eq('http://ollama.internal:11434')
            expect(err.reason).to eq('connection_refused')
          end
      end
    end

    context 'when Ollama probe times out' do
      it 'raises ProviderUnreachable with reason: "timeout" on Net::OpenTimeout' do
        stub_net_http_raise('ollama.internal', 11_434, Net::OpenTimeout)

        expect { described_class.reachable!(ollama_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.reason).to eq('timeout')
          end
      end

      it 'raises ProviderUnreachable with reason: "timeout" on Net::ReadTimeout' do
        http_double = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).with('ollama.internal', 11_434).and_return(http_double)
        allow(http_double).to receive(:open_timeout=)
        allow(http_double).to receive(:read_timeout=)
        allow(http_double).to receive(:use_ssl=)
        allow(http_double).to receive(:start).and_yield(http_double)
        allow(http_double).to receive(:get).and_raise(Net::ReadTimeout)

        expect { described_class.reachable!(ollama_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.reason).to eq('timeout')
          end
      end
    end

    context 'when Ollama returns a 5xx server error' do
      it 'raises ProviderUnreachable with reason: "http_500"' do
        response = instance_double(Net::HTTPServiceUnavailable)
        allow(response).to receive(:is_a?).with(Net::HTTPServerError).and_return(true)
        stub_net_http('ollama.internal', 11_434, response)

        expect { described_class.reachable!(ollama_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.reason).to eq('http_500')
          end
      end
    end

    context 'when Ollama DNS resolution fails' do
      it 'raises ProviderUnreachable with reason: "dns_failure"' do
        stub_net_http_raise('ollama.internal', 11_434,
                            SocketError.new('getaddrinfo: Name or service not known'))

        expect { described_class.reachable!(ollama_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.reason).to eq('dns_failure')
          end
      end
    end

    # --- OpenAI ---

    context 'when OpenAI responds with 200' do
      it 'returns the provider unchanged' do
        response = instance_double(Net::HTTPOK)
        allow(response).to receive(:is_a?).with(Net::HTTPUnauthorized).and_return(false)
        allow(response).to receive(:is_a?).with(Net::HTTPForbidden).and_return(false)
        allow(response).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
        stub_net_http('api.openai.com', 443, response)

        result = described_class.reachable!(openai_provider)
        expect(result).to be(openai_provider)
      end

      it 'probes GET /v1/models over TLS' do
        response = instance_double(Net::HTTPOK)
        allow(response).to receive(:is_a?).with(Net::HTTPUnauthorized).and_return(false)
        allow(response).to receive(:is_a?).with(Net::HTTPForbidden).and_return(false)
        allow(response).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
        http_double = stub_net_http('api.openai.com', 443, response)
        allow(http_double).to receive(:use_ssl=).with(true)

        described_class.reachable!(openai_provider)
        expect(http_double).to have_received(:use_ssl=).with(true)
        expect(http_double).to have_received(:get).with('/v1/models')
      end
    end

    context 'when OpenAI returns 401 Unauthorized' do
      it 'raises ProviderUnreachable with reason: "unauthorized"' do
        response = instance_double(Net::HTTPUnauthorized)
        allow(response).to receive(:is_a?).with(Net::HTTPUnauthorized).and_return(true)
        stub_net_http('api.openai.com', 443, response)

        expect { described_class.reachable!(openai_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.url).to eq('https://api.openai.com')
            expect(err.reason).to eq('unauthorized')
          end
      end
    end

    context 'when OpenAI returns 403 Forbidden' do
      # Observed when an edge proxy (corporate firewall, geo-blocked region)
      # intercepts the probe before it reaches OpenAI's auth layer. Treating
      # 403 as reachable would give operators a false-green status — the
      # real embed calls will 403 the same way.
      it 'raises ProviderUnreachable with reason: "forbidden"' do
        response = instance_double(Net::HTTPForbidden)
        allow(response).to receive(:is_a?).with(Net::HTTPUnauthorized).and_return(false)
        allow(response).to receive(:is_a?).with(Net::HTTPForbidden).and_return(true)
        stub_net_http('api.openai.com', 443, response)

        expect { described_class.reachable!(openai_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.url).to eq('https://api.openai.com')
            expect(err.reason).to eq('forbidden')
          end
      end
    end

    context 'when OpenAI is unreachable (connection refused)' do
      it 'raises ProviderUnreachable with reason: "connection_refused"' do
        stub_net_http_raise('api.openai.com', 443, Errno::ECONNREFUSED)

        expect { described_class.reachable!(openai_provider) }
          .to raise_error(Woods::MCP::ProviderUnreachable) do |err|
            expect(err.url).to eq('https://api.openai.com')
            expect(err.reason).to eq('connection_refused')
          end
      end
    end

    # --- Fake provider (#178) ---

    context 'with the deterministic fake provider' do
      it 'is trivially reachable without any network I/O' do
        fake = Woods::Embedding::Provider::Fake.new(dims: 8)
        expect(Net::HTTP).not_to receive(:new)

        expect(described_class.reachable!(fake)).to be(fake)
      end
    end

    # --- Injected provider object (#178) ---

    context 'with an injected provider object' do
      # Builder#build_embedding_provider accepts an already-constructed
      # object responding to #embed/#embed_batch. The probe used to fall
      # through to the ArgumentError arm for those, crashing MCP boot for a
      # host whose retrieval works fine — Bootstrapper only rescues
      # ProviderUnreachable.
      it 'is presumed reachable and returned as-is' do
        injected = double('HostProvider', embed: [0.0], embed_batch: [[0.0]])

        expect(described_class.reachable!(injected)).to be(injected)
      end

      it 'performs no network I/O' do
        injected = double('HostProvider', embed: [0.0], embed_batch: [[0.0]])
        expect(Net::HTTP).not_to receive(:new)

        described_class.reachable!(injected)
      end
    end

    # --- Unknown provider ---

    context 'with an object that is not a provider at all' do
      it 'raises ArgumentError naming the #embed/#embed_batch contract' do
        opaque = Object.new

        expect { described_class.reachable!(opaque) }
          .to raise_error(ArgumentError,
                          /does not know how to probe Object.*must implement #embed and #embed_batch/m)
      end

      it 'raises ArgumentError when only #embed is implemented' do
        half_provider = double('HalfProvider', embed: [0.0])

        expect { described_class.reachable!(half_provider) }
          .to raise_error(ArgumentError, /does not know how to probe/)
      end
    end

    # --- Structured exception fields ---

    context 'exception structure' do
      it 'exposes #url and #reason on the raised exception' do
        stub_net_http_raise('ollama.internal', 11_434, Errno::ECONNREFUSED)

        begin
          described_class.reachable!(ollama_provider)
        rescue Woods::MCP::ProviderUnreachable => e
          expect(e.url).to be_a(String)
          expect(e.reason).to be_a(String)
          expect(e.message).to include(e.url).or include(e.reason)
        end
      end
    end
  end

  # spec_helper loads the full gem, so an in-process example can never see a
  # missing sibling require — same rationale as spec/load_order_spec.rb.
  # The probe dispatches on Provider::OpenAI/Ollama/Fake at call time;
  # requiring only fake.rb left Provider::OpenAI undefined for a standalone
  # `require 'woods/mcp/provider_probe'`, so the first probe of an OpenAI
  # provider raised NameError instead of probing.
  describe 'standalone load' do
    it 'defines every provider class the probe dispatches on' do
      require 'open3'
      stdout, status = Open3.capture2e(
        'ruby', '-Ilib', '-rwoods/mcp/provider_probe',
        '-e', 'exit(defined?(Woods::Embedding::Provider::OpenAI) && ' \
              'defined?(Woods::Embedding::Provider::Ollama) && ' \
              'defined?(Woods::Embedding::Provider::Fake) && ' \
              'defined?(Woods::MCP::ProviderUnreachable) ? 0 : 1)'
      )
      expect(status).to be_success,
                        "provider_probe did not self-load its dispatch constants:\n#{stdout}"
    end
  end
end
