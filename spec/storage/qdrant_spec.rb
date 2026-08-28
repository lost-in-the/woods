# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'net/http'
require 'openssl'
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
    allow(http).to receive(:finish)
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
    it 'creates an absent collection with the configured dimensions' do
      absent = instance_double(Net::HTTPNotFound, code: '404', body: '{"status":"not found"}')
      created = instance_double(Net::HTTPSuccess, code: '200', body: '{"result":true}')
      allow(absent).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(absent).to receive(:[]).with('Retry-After').and_return(nil)
      allow(created).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(absent, created)

      store.ensure_collection!(dimensions: 384)

      requests = []
      expect(http).to have_received(:request).twice do |request|
        requests << request
      end
      expect(requests.map(&:method)).to eq(%w[GET PUT])
      expect(JSON.parse(requests.last.body)).to eq(
        'vectors' => { 'size' => 384, 'distance' => 'Cosine' }
      )
    end

    it 'keeps a compatible existing collection without recreating it' do
      body = { result: { config: { params: { vectors: { size: 384, distance: 'Cosine' } } } } }.to_json
      response = instance_double(Net::HTTPSuccess, code: '200', body: body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      store.ensure_collection!(dimensions: 384)

      expect(http).to have_received(:request).once do |request|
        expect(request).to be_a(Net::HTTP::Get)
      end
    end

    it 'rejects an existing collection with a different dimension' do
      body = { result: { config: { params: { vectors: { size: 768, distance: 'Cosine' } } } } }.to_json
      response = instance_double(Net::HTTPSuccess, code: '200', body: body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect { store.ensure_collection!(dimensions: 384) }
        .to raise_error(Woods::ConfigurationError, /dimension mismatch.*384.*768/i)
    end

    it 'rejects a distance mismatch before any write' do
      body = { result: { config: { params: { vectors: { size: 384, distance: 'Cosine' } } } } }.to_json
      response = instance_double(Net::HTTPSuccess, code: '200', body: body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)
      dot_store = described_class.new(url: 'http://localhost:6333', collection: 'test_collection',
                                      dimensions: 384, distance: 'Dot', allow_private_hosts: true)
      allow(dot_store).to receive(:http_client).and_return(http)

      expect { dot_store.ensure_collection!(dimensions: 384) }
        .to raise_error(Woods::ConfigurationError, /distance mismatch.*Dot.*Cosine/i)
      expect(http).to have_received(:request).once
    end

    it 'rejects named vectors because this adapter sends unnamed vectors' do
      vectors = { text: { size: 384, distance: 'Cosine' } }
      response_body = { result: { config: { params: { vectors: vectors } } } }.to_json
      response = instance_double(Net::HTTPSuccess, code: '200', body: response_body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect { store.ensure_collection!(dimensions: 384) }
        .to raise_error(Woods::ConfigurationError, /named vectors.*not supported/i)
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
        # ?wait=true is load-bearing, not cosmetic: Qdrant acknowledges an
        # un-awaited write before it is readable, so the embed pipeline's
        # write-then-dump and the prune paths' delete-then-count would both
        # observe stale state without it.
        expect(req.path).to eq("/collections/test_collection/points#{described_class::WAIT_FOR_WRITE}")
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
      allow(response).to receive(:[]).with('Retry-After').and_return(nil)
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
        # ?wait=true is load-bearing, not cosmetic: Qdrant acknowledges an
        # un-awaited write before it is readable, so the embed pipeline's
        # write-then-dump and the prune paths' delete-then-count would both
        # observe stale state without it.
        expect(req.path).to eq("/collections/test_collection/points#{described_class::WAIT_FOR_WRITE}")
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
        expect(req.path).to eq("/collections/test_collection/points/delete#{described_class::WAIT_FOR_WRITE}")
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
        expect(req.path).to eq("/collections/test_collection/points/delete#{described_class::WAIT_FOR_WRITE}")
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

  describe '#each_id' do
    def success(body)
      response = instance_double(Net::HTTPSuccess, code: '200', body: body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      response
    end

    # Point ids on the wire are UUIDv5. Yielding those instead of the Woods
    # identifiers would make reconciliation compare UUIDs against extraction
    # output, conclude every unit had vanished, and delete the whole index.
    it 'yields Woods identifiers, not point ids' do
      body = {
        result: {
          points: [
            { id: described_class.point_id('User'), payload: { woods_identifier: 'User' } },
            { id: described_class.point_id('Post#chunk_0'), payload: { woods_identifier: 'Post#chunk_0' } }
          ],
          next_page_offset: nil
        }
      }.to_json
      allow(http).to receive(:request).and_return(success(body))

      expect(store.each_id.to_a).to eq(['User', 'Post#chunk_0'])
    end

    it 'requests only the identifier payload and no vectors' do
      allow(http).to receive(:request)
        .and_return(success('{"result":{"points":[],"next_page_offset":null}}'))

      store.each_id.to_a

      expect(http).to have_received(:request) do |req|
        expect(req.path).to eq('/collections/test_collection/points/scroll')
        body = JSON.parse(req.body)
        expect(body['with_vector']).to be(false)
        expect(body['with_payload']).to eq(['woods_identifier'])
      end
    end

    it 'follows next_page_offset until the scroll is exhausted' do
      page1 = success({ result: { points: [{ id: 1, payload: { woods_identifier: 'A' } }],
                                  next_page_offset: 'cursor-2' } }.to_json)
      page2 = success({ result: { points: [{ id: 2, payload: { woods_identifier: 'B' } }],
                                  next_page_offset: nil } }.to_json)
      allow(http).to receive(:request).and_return(page1, page2)

      expect(store.each_id.to_a).to eq(%w[A B])
      expect(http).to have_received(:request).twice
    end

    it 'falls back to the raw point id for points this adapter did not write' do
      body = { result: { points: [{ id: 'foreign-id', payload: {} }], next_page_offset: nil } }.to_json
      allow(http).to receive(:request).and_return(success(body))

      expect(store.each_id.to_a).to eq(['foreign-id'])
    end
  end

  describe '#stored_dimensions' do
    it 'reads the collection vector size' do
      body = { result: { config: { params: { vectors: { size: 384, distance: 'Cosine' } } } } }.to_json
      response = instance_double(Net::HTTPSuccess, code: '200', body: body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect(store.stored_dimensions).to eq(384)
    end

    it 'returns nil rather than raising when the collection is absent' do
      response = instance_double(Net::HTTPNotFound, code: '404', body: '{"status":"not found"}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(response).to receive(:[]).with('Retry-After').and_return(nil)
      allow(http).to receive(:request).and_return(response)

      expect(store.stored_dimensions).to be_nil
    end

    it 'does not disguise an authentication failure as an absent collection' do
      response = instance_double(Net::HTTPUnauthorized, code: '401', body: '{"status":"unauthorized"}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(response).to receive(:[]).with('Retry-After').and_return(nil)
      allow(http).to receive(:request).and_return(response)

      expect { store.stored_dimensions }
        .to raise_error(Woods::Error, /Qdrant API error: 401/)
    end

    # Named vectors produce a different shape; this adapter never writes them,
    # so the honest answer is "unknown" rather than a wrong number.
    it 'returns nil for an unrecognized vectors shape' do
      body = { result: { config: { params: { vectors: { 'text' => { 'size' => 384 } } } } } }.to_json
      response = instance_double(Net::HTTPSuccess, code: '200', body: body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect(store.stored_dimensions).to be_nil
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
    it 'closes a discarded connection before replacing it (no leaked socket)' do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)
      allow(http).to receive(:started?).and_return(true, false, true)

      expect { store.count }.to raise_error(described_class::RequestError)

      # Net::HTTP.new is stubbed to the same double, so both the first
      # discard and the post-retry discard close that (shared) client.
      expect(http).to have_received(:finish).twice
    end

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

    it 'wraps a second read timeout after one safe retry' do
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)
      allow(http).to receive(:started?).and_return(true, false, true)

      expect { store.count }
        .to raise_error(described_class::RequestError) do |error|
          expect(error).to be_retryable
          expect(error).not_to be_ambiguous
        end
      expect(http).to have_received(:request).twice
    end

    it 'does not blindly retry an ambiguous upsert timeout' do
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)
      allow(http).to receive(:started?).and_return(true, false, true)

      expect { store.store('doc1', [0.1, 0.2, 0.3], {}) }
        .to raise_error(described_class::RequestError) do |error|
          expect(error).to be_retryable
          expect(error).to be_ambiguous
        end
      expect(http).to have_received(:request).once
    end

    it 'wraps a write timeout as ambiguous without retrying the write' do
      allow(http).to receive(:request).and_raise(Net::WriteTimeout)

      expect { store.store('doc1', [0.1, 0.2, 0.3], {}) }
        .to raise_error(described_class::RequestError) do |error|
          expect(error).to be_retryable
          expect(error).to be_ambiguous
        end
      expect(http).to have_received(:request).once
    end

    it 'retries a read after a write timeout with non-ambiguous classification' do
      allow(http).to receive(:request).and_raise(Net::WriteTimeout)
      allow(http).to receive(:started?).and_return(true, false, true)

      expect { store.count }
        .to raise_error(described_class::RequestError) do |error|
          expect(error).to be_retryable
          expect(error).not_to be_ambiguous
        end
      expect(http).to have_received(:request).twice
    end

    [Errno::ECONNREFUSED, SocketError].each do |error_class|
      it "wraps #{error_class} as retryable and non-ambiguous" do
        allow(http).to receive(:request).and_raise(error_class, 'unavailable')
        allow(http).to receive(:started?).and_return(true, false, true)

        expect { store.store('doc1', [0.1, 0.2, 0.3], {}) }
          .to raise_error(described_class::RequestError) do |error|
            expect(error).to be_retryable
            expect(error).not_to be_ambiguous
          end
        expect(http).to have_received(:request).twice
      end
    end

    it 'does not retry an unknown non-idempotent POST after an ambiguous timeout' do
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)

      expect { store.send(:request, :post, '/collections/test_collection/custom-write', {}) }
        .to raise_error(described_class::RequestError) { |error| expect(error).to be_ambiguous }
      expect(http).to have_received(:request).once
    end

    it 'wraps the error when retry also fails' do
      allow(http).to receive(:request).and_raise(Errno::ECONNRESET)
      allow(http).to receive(:started?).and_return(true, false, true)

      expect { store.count }.to raise_error(described_class::RequestError, /connection reset/i)
    end
  end

  describe 'HTTP failure classification' do
    { 401 => Net::HTTPUnauthorized, 403 => Net::HTTPForbidden }.each do |status, response_class|
      it "reports #{status} as a non-retryable configuration failure" do
        response = instance_double(response_class, code: status.to_s, body: '{"status":"denied"}')
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(response).to receive(:[]).with('Retry-After').and_return(nil)
        allow(http).to receive(:request).and_return(response)

        expect { store.count }
          .to raise_error(described_class::RequestError) do |error|
            expect(error.http_status).to eq(status)
            expect(error).not_to be_retryable
          end
      end
    end

    { 429 => Net::HTTPTooManyRequests, 503 => Net::HTTPServiceUnavailable }.each do |status, response_class|
      it "reports #{status} as retryable and preserves Retry-After" do
        response = instance_double(response_class, code: status.to_s, body: '{"status":"busy"}')
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(response).to receive(:[]).with('Retry-After').and_return('2')
        allow(http).to receive(:request).and_return(response)

        expect { store.count }
          .to raise_error(described_class::RequestError) do |error|
            expect(error.http_status).to eq(status)
            expect(error.retry_after).to eq('2')
            expect(error).to be_retryable
          end
      end
    end

    it 'wraps TLS failures without retrying them blindly' do
      allow(http).to receive(:request).and_raise(OpenSSL::SSL::SSLError, 'certificate verify failed')

      expect { store.count }
        .to raise_error(described_class::RequestError, /TLS.*certificate verify failed/i)
      expect(http).to have_received(:request).once
    end

    it 'wraps malformed JSON success responses with endpoint context' do
      response = instance_double(Net::HTTPSuccess, code: '200', body: 'not-json{{')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http).to receive(:request).and_return(response)

      expect { store.count }
        .to raise_error(described_class::RequestError, %r{malformed JSON.*points/count}i)
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
