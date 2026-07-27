# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'net/http'
require 'woods'
require 'woods/storage/vector_store'
require 'woods/storage/qdrant'

RSpec.describe Woods::Storage::VectorStore::Qdrant do
  let(:store) { described_class.new(url: 'http://localhost:6333', collection: 'test_collection', allow_private_hosts: true) }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:keep_alive_timeout=)
    allow(http).to receive(:start).and_return(http)
    allow(http).to receive(:started?).and_return(true)
  end

  describe '#initialize' do
    it 'creates a store with url and collection' do
      expect(store).to be_a(described_class)
    end

    it 'accepts an optional api_key' do
      store_with_key = described_class.new(url: 'http://localhost:6333', collection: 'test',
                                           api_key: 'secret', allow_private_hosts: true)
      expect(store_with_key).to be_a(described_class)
    end
  end

  describe '#ensure_collection!' do
    it 'sends a PUT request to create the collection' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":true}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.ensure_collection!(dimensions: 384)

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Put)
        expect(req.path).to eq('/collections/test_collection')
        body = JSON.parse(req.body)
        expect(body['vectors']['size']).to eq(384)
        expect(body['vectors']['distance']).to eq('Cosine')
      end
    end
  end

  describe '#store' do
    it 'sends a PUT request to upsert points' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.store('doc1', [0.1, 0.2, 0.3], { type: 'model' })

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Put)
        expect(req.path).to eq('/collections/test_collection/points')
        body = JSON.parse(req.body)
        point = body['points'].first
        expect(point['id']).to eq(described_class.point_id('doc1'))
        expect(point['vector']).to eq([0.1, 0.2, 0.3])
        expect(point['payload']).to eq({ 'type' => 'model', 'woods_identifier' => 'doc1' })
      end
    end

    it 'raises on API error' do
      response = instance_double(Net::HTTPInternalServerError, code: '500', body: 'Internal error')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http).to receive(:request).and_return(response)

      expect { store.store('doc1', [0.1], {}) }.to raise_error(Woods::Error, /Qdrant API error/)
    end
  end

  describe '#store_batch' do
    it 'sends all entries in a single PUT request' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      entries = [
        { id: 'doc1', vector: [0.1, 0.2, 0.3], metadata: { type: 'model' } },
        { id: 'doc2', vector: [0.4, 0.5, 0.6], metadata: { type: 'service' } }
      ]

      store.store_batch(entries)

      expect(http).to have_received(:request).once do |req|
        expect(req).to be_a(Net::HTTP::Put)
        expect(req.path).to eq('/collections/test_collection/points')
        body = JSON.parse(req.body)
        expect(body['points'].size).to eq(2)
        expect(body['points'][0]['id']).to eq(described_class.point_id('doc1'))
        expect(body['points'][1]['id']).to eq(described_class.point_id('doc2'))
      end
    end

    it 'does nothing for empty entries' do
      allow(http).to receive(:request)

      store.store_batch([])

      expect(http).not_to have_received(:request)
    end

    it 'defaults metadata to empty hash when not provided' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      entries = [{ id: 'doc1', vector: [0.1, 0.2, 0.3] }]

      store.store_batch(entries)

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['points'][0]['payload']).to eq({ 'woods_identifier' => 'doc1' })
      end
    end
  end

  describe '#search' do
    let(:search_response_body) do
      {
        result: [
          { id: described_class.point_id('doc1'), score: 0.95,
            payload: { type: 'model', woods_identifier: 'doc1' } },
          { id: described_class.point_id('doc2'), score: 0.80,
            payload: { type: 'service', woods_identifier: 'doc2' } }
        ]
      }.to_json
    end

    before do
      response = instance_double(Net::HTTPSuccess, code: '200', body: search_response_body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)
    end

    it 'returns an array of SearchResult objects' do
      results = store.search([0.1, 0.2, 0.3], limit: 10)

      expect(results).to all(be_a(Woods::Storage::VectorStore::SearchResult))
      expect(results.size).to eq(2)
    end

    it 'maps score and metadata correctly' do
      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.id).to eq('doc1')
      expect(results.first.score).to eq(0.95)
      expect(results.first.metadata).to eq({ 'type' => 'model', 'woods_identifier' => 'doc1' })
    end

    it 'sends the correct limit' do
      store.search([0.1, 0.2, 0.3], limit: 5)

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body['limit']).to eq(5)
      end
    end

    it 'applies metadata filters using Qdrant must conditions' do
      store.search([0.1, 0.2, 0.3], filters: { type: 'model' })

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        must_conditions = body['filter']['must']
        expect(must_conditions).to include({ 'key' => 'type', 'match' => { 'value' => 'model' } })
      end
    end

    it 'omits filter when filters are empty' do
      store.search([0.1, 0.2, 0.3], filters: {})

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        expect(body).not_to have_key('filter')
      end
    end

    it 'translates an Array filter value into match.any membership (#108)' do
      store.search([0.1, 0.2, 0.3], filters: { type: %w[model service] })

      expect(http).to have_received(:request) do |req|
        body = JSON.parse(req.body)
        must_conditions = body['filter']['must']
        expect(must_conditions).to include(
          { 'key' => 'type', 'match' => { 'any' => %w[model service] } }
        )
      end
    end
  end

  describe '#delete' do
    it 'sends a POST request to delete a point by its UUID point ID' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.delete('doc1')

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        expect(req.path).to eq('/collections/test_collection/points/delete')
        body = JSON.parse(req.body)
        expect(body['points']).to eq([described_class.point_id('doc1')])
      end
    end

    # The whole reason delete goes through the same translation as upsert:
    # a delete that computes a different id silently retains the vector.
    it 'deletes the exact point ID that #store wrote (#147)' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.store('Api::V1::UsersController', [0.1, 0.2, 0.3], {})
      store.delete('Api::V1::UsersController')

      stored_id, deleted_ids = nil
      expect(http).to have_received(:request).twice do |req|
        body = JSON.parse(req.body)
        stored_id = body['points'].first['id'] if req.is_a?(Net::HTTP::Put)
        deleted_ids = body['points'] if req.is_a?(Net::HTTP::Post)
      end

      expect(deleted_ids).to eq([stored_id])
    end
  end

  describe '#delete_by_filter' do
    it 'sends a POST request to delete by filter' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.delete_by_filter({ type: 'model' })

      expect(http).to have_received(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        expect(req.path).to eq('/collections/test_collection/points/delete')
        body = JSON.parse(req.body)
        expect(body['filter']['must']).to include({ 'key' => 'type', 'match' => { 'value' => 'model' } })
      end
    end
  end

  describe '#count' do
    it 'returns the number of stored vectors' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":42}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect(store.count).to eq(42)
    end
  end

  describe 'HTTP timeout configuration' do
    it 'sets open_timeout on the HTTP connection' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.count

      expect(http).to have_received(:open_timeout=).with(10)
    end

    it 'sets read_timeout on the HTTP connection' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.count

      expect(http).to have_received(:read_timeout=).with(30)
    end
  end

  describe 'connection retry' do
    it 'retries once on ECONNRESET' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      call_count = 0
      allow(http).to receive(:request) do
        call_count += 1
        raise Errno::ECONNRESET if call_count == 1

        response
      end
      allow(http).to receive(:started?).and_return(true, false, true)

      expect(store.count).to eq(0)
    end

    it 'propagates error when retry also fails' do
      allow(http).to receive(:request).and_raise(Errno::ECONNRESET)
      allow(http).to receive(:started?).and_return(true, false, true)

      expect { store.count }.to raise_error(Errno::ECONNRESET)
    end
  end

  # Qdrant accepts only an unsigned integer or a UUID as a point id. Woods
  # identifiers are neither, so the adapter maps them to a deterministic
  # UUIDv5 and carries the identifier in the payload. See #147 / B-058.
  describe '.point_id' do
    it 'maps a Woods identifier to a canonical UUID' do
      expect(described_class.point_id('User'))
        .to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it 'maps a namespaced identifier to a canonical UUID' do
      expect(described_class.point_id('Api::V1::UsersController'))
        .to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it 'maps a chunk-suffixed embed id to a canonical UUID' do
      expect(described_class.point_id('User#chunk_0'))
        .to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    # Stability is the correctness property: a re-embed of an unchanged
    # unit must land on the same point so the upsert replaces rather than
    # duplicates. Pinned against the literal, not against a second call —
    # a self-comparison would pass even if the namespace drifted.
    it 'is stable for a given identifier' do
      expect(described_class.point_id('User')).to eq('0c41a4f5-8239-564d-bbe1-50aee008ba5c')
    end

    it 'derives the id from the pinned namespace and the identifier' do
      expect(described_class.point_id('User')).to eq(
        Woods::Util::UUID5.generate(described_class::POINT_ID_NAMESPACE, 'User')
      )
    end

    it 'distinguishes a unit from its own chunks' do
      expect(described_class.point_id('User')).not_to eq(described_class.point_id('User#chunk_0'))
    end

    it 'distinguishes sibling chunks' do
      expect(described_class.point_id('User#chunk_0')).not_to eq(described_class.point_id('User#chunk_1'))
    end

    it 'passes an integer point ID through untouched' do
      expect(described_class.point_id(42)).to eq(42)
    end

    it 'passes an already-canonical UUID through untouched' do
      uuid = '886313e1-3b8a-5372-9b90-0c9aee199e5d'

      expect(described_class.point_id(uuid)).to eq(uuid)
    end
  end

  describe 'search reverse mapping' do
    def stub_search(result)
      response = instance_double(Net::HTTPSuccess, code: '200', body: { result: result }.to_json)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)
    end

    it 'returns the Woods identifier rather than the UUID point ID' do
      stub_search([{ id: described_class.point_id('User'), score: 0.9,
                     payload: { woods_identifier: 'User' } }])

      expect(store.search([0.1, 0.2, 0.3]).first.id).to eq('User')
    end

    it 'restores a chunk-suffixed embed id, matching pgvector' do
      stub_search([{ id: described_class.point_id('User#chunk_2'), score: 0.9,
                     payload: { woods_identifier: 'User#chunk_2' } }])

      expect(store.search([0.1, 0.2, 0.3]).first.id).to eq('User#chunk_2')
    end

    it 'round-trips every identifier a store call would have written' do
      identifiers = ['User', 'Api::V1::UsersController', 'User#chunk_0', 'app/views/x.html.erb']
      stub_search(identifiers.map do |id|
        { id: described_class.point_id(id), score: 0.5, payload: { woods_identifier: id } }
      end)

      expect(store.search([0.1, 0.2, 0.3], limit: 10).map(&:id)).to eq(identifiers)
    end

    it 'falls back to the raw point ID when the payload carries no mapping' do
      stub_search([{ id: 'legacy-id', score: 0.9, payload: { type: 'model' } }])

      expect(store.search([0.1, 0.2, 0.3]).first.id).to eq('legacy-id')
    end

    it 'tolerates a hit with no payload at all' do
      stub_search([{ id: 7, score: 0.9 }])

      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.id).to eq(7)
      expect(results.first.metadata).to eq({})
    end

    it 'does not clobber the base identifier the Indexer writes to the payload' do
      # The Indexer's metadata carries `identifier` = the *base* unit id,
      # while the point id derives from the chunk-suffixed embed id.
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"status":"completed"}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.store('User#chunk_1', [0.1, 0.2, 0.3], { type: 'model', identifier: 'User' })

      expect(http).to have_received(:request) do |req|
        payload = JSON.parse(req.body)['points'].first['payload']
        expect(payload['identifier']).to eq('User')
        expect(payload['woods_identifier']).to eq('User#chunk_1')
      end
    end
  end

  describe 'Interface compliance' do
    it 'includes VectorStore::Interface' do
      expect(described_class.ancestors).to include(Woods::Storage::VectorStore::Interface)
    end
  end

  describe 'API key authentication' do
    it 'includes api-key header when api_key is provided' do
      store_with_key = described_class.new(url: 'http://localhost:6333', collection: 'test',
                                           api_key: 'secret-key', allow_private_hosts: true)
      response = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":{"count":0}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store_with_key.count

      expect(http).to have_received(:request) do |req|
        expect(req['api-key']).to eq('secret-key')
      end
    end
  end

  describe 'URL validation (SSRF defense)' do
    it 'rejects file:// schemes' do
      expect do
        described_class.new(url: 'file:///etc/passwd', collection: 'x')
      end.to raise_error(ArgumentError, /scheme must be one of/)
    end

    it 'rejects gopher:// schemes' do
      expect do
        described_class.new(url: 'gopher://evil/', collection: 'x')
      end.to raise_error(ArgumentError, /scheme must be one of/)
    end

    it 'rejects URLs with no host' do
      expect do
        described_class.new(url: 'http:///', collection: 'x')
      end.to raise_error(ArgumentError, /must include a host/)
    end

    it 'rejects the AWS IMDS address by default' do
      expect do
        described_class.new(url: 'http://169.254.169.254/', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects RFC1918 hosts by default' do
      expect do
        described_class.new(url: 'http://10.0.0.5:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects localhost by default' do
      expect do
        described_class.new(url: 'http://localhost:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'permits loopback when allow_private_hosts: true is set explicitly' do
      expect do
        described_class.new(url: 'http://127.0.0.1:6333', collection: 'x', allow_private_hosts: true)
      end.not_to raise_error
    end

    it 'permits an ordinary public hostname' do
      expect do
        described_class.new(url: 'https://qdrant.example.com:6333', collection: 'x')
      end.not_to raise_error
    end

    it 'rejects the wildcard 0.0.0.0 address' do
      expect do
        described_class.new(url: 'http://0.0.0.0:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects CGNAT (100.64.0.0/10) addresses' do
      expect do
        described_class.new(url: 'http://100.64.5.1:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects IPv6 ULA fc00::/7 addresses' do
      expect do
        described_class.new(url: 'http://[fc00::1]:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects IPv6 link-local fe80::/10 addresses' do
      expect do
        described_class.new(url: 'http://[fe80::1]:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects IPv4-mapped IPv6 for the AWS IMDS' do
      expect do
        described_class.new(url: 'http://[::ffff:169.254.169.254]:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects a trailing-dot "localhost." form' do
      expect do
        described_class.new(url: 'http://localhost.:6333', collection: 'x')
      end.to raise_error(ArgumentError, %r{private/loopback host})
    end

    it 'rejects a hex-notation IPv4 host (0x7f000001 = 127.0.0.1)' do
      expect do
        described_class.new(url: 'http://0x7f000001:6333', collection: 'x')
      end.to raise_error(ArgumentError, /non-standard numeric host/)
    end

    it 'rejects a bare-integer IPv4 host (2130706433 = 127.0.0.1)' do
      expect do
        described_class.new(url: 'http://2130706433:6333', collection: 'x')
      end.to raise_error(ArgumentError, /non-standard numeric host/)
    end

    it 'rejects a leading-zero octal form (0177.0.0.1 = 127.0.0.1)' do
      expect do
        described_class.new(url: 'http://0177.0.0.1:6333', collection: 'x')
      end.to raise_error(ArgumentError, /non-standard numeric host/)
    end

    it 'rejects short-form IPv4 (127.1 = 127.0.0.1)' do
      expect do
        described_class.new(url: 'http://127.1:6333', collection: 'x')
      end.to raise_error(ArgumentError, /non-standard numeric host/)
    end

    it 'rejects mixed-radix IPv4 (0x7f.0.0.1 = 127.0.0.1)' do
      expect do
        described_class.new(url: 'http://0x7f.0.0.1:6333', collection: 'x')
      end.to raise_error(ArgumentError, /non-standard numeric host/)
    end

    it 'still accepts standard dotted-decimal IPv4' do
      expect do
        described_class.new(url: 'http://203.0.113.5:6333', collection: 'x')
      end.not_to raise_error
    end
  end
end
