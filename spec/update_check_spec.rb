# frozen_string_literal: true

require 'spec_helper'
require 'woods/update_check'
require 'tmpdir'
require 'json'

RSpec.describe Woods::UpdateCheck do
  let(:cache_path) { File.join(Dir.mktmpdir, 'update_check.json') }
  let(:now) { Time.at(1_700_000_000) }

  describe '.check' do
    it 'reports an update when the fetched latest version is newer' do
      result = described_class.check(
        current: '1.5.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { '1.6.0' }
      )

      expect(result[:current]).to eq('1.5.0')
      expect(result[:latest]).to eq('1.6.0')
      expect(result[:update_available]).to be(true)
    end

    it 'reports no update when the installed version is current or newer' do
      result = described_class.check(
        current: '1.6.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { '1.6.0' }
      )

      expect(result[:update_available]).to be(false)

      ahead = described_class.check(
        current: '1.7.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { '1.6.0' }
      )
      expect(ahead[:update_available]).to be(false)
    end

    it 'writes a cache entry and reuses it within the TTL without re-fetching' do
      calls = 0
      fetcher = lambda do |_url|
        calls += 1
        '1.6.0'
      end

      described_class.check(current: '1.5.0', cache_path: cache_path, now: now, fetcher: fetcher)
      described_class.check(current: '1.5.0', cache_path: cache_path, now: now + 60, fetcher: fetcher)

      expect(calls).to eq(1)
      expect(JSON.parse(File.read(cache_path))).to include('latest' => '1.6.0')
    end

    it 're-fetches once the cache is older than the TTL' do
      calls = 0
      fetcher = lambda do |_url|
        calls += 1
        '1.6.0'
      end

      described_class.check(current: '1.5.0', cache_path: cache_path, now: now, fetcher: fetcher)
      described_class.check(
        current: '1.5.0', cache_path: cache_path,
        now: now + described_class::CACHE_TTL + 1, fetcher: fetcher
      )

      expect(calls).to eq(2)
    end

    it 'degrades gracefully when the fetch fails (no update signal, no raise)' do
      result = described_class.check(
        current: '1.5.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { raise SocketError, 'offline' }
      )

      expect(result[:latest]).to be_nil
      expect(result[:update_available]).to be(false)
    end

    it 'negative-caches a failed probe and does not re-fetch within FAILURE_TTL' do
      calls = 0
      fetcher = lambda do |_url|
        calls += 1
        raise SocketError, 'offline'
      end

      described_class.check(current: '1.5.0', cache_path: cache_path, now: now, fetcher: fetcher)
      described_class.check(current: '1.5.0', cache_path: cache_path, now: now + 60, fetcher: fetcher)

      expect(calls).to eq(1)
    end

    it 're-probes after FAILURE_TTL elapses' do
      calls = 0
      fetcher = lambda do |_url|
        calls += 1
        nil
      end

      described_class.check(current: '1.5.0', cache_path: cache_path, now: now, fetcher: fetcher)
      described_class.check(
        current: '1.5.0', cache_path: cache_path,
        now: now + described_class::FAILURE_TTL + 1, fetcher: fetcher
      )

      expect(calls).to eq(2)
    end

    it 'ignores a corrupt cache whose JSON is not an object (degrades, never raises)' do
      File.write(cache_path, '[]')

      result = nil
      expect do
        result = described_class.check(
          current: '1.5.0', cache_path: cache_path, now: now, fetcher: ->(_url) {}
        )
      end.not_to raise_error
      expect(result[:update_available]).to be(false)
    end

    it 'is a no-op when disabled via WOODS_NO_UPDATE_CHECK' do
      calls = 0
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WOODS_NO_UPDATE_CHECK').and_return('1')

      result = described_class.check(
        current: '1.5.0', cache_path: cache_path, now: now,
        fetcher: lambda { |_url|
          calls += 1
          '1.6.0'
        }
      )

      expect(calls).to eq(0)
      expect(result[:update_available]).to be(false)
    end
  end

  describe '.status_hash' do
    it 'exposes current/latest/update_available with string-friendly keys' do
      hash = described_class.status_hash(
        current: '1.5.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { '1.6.0' }
      )

      expect(hash).to eq(
        current_version: '1.5.0',
        latest_version: '1.6.0',
        update_available: true
      )
    end

    it 'reports the installed version as latest_version when it is ahead of the registry' do
      hash = described_class.status_hash(
        current: '2.0.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { '1.6.0' }
      )

      expect(hash).to eq(
        current_version: '2.0.0',
        latest_version: '2.0.0',
        update_available: false
      )
    end

    it 'reports the installed version as latest_version when the registry probe fails' do
      hash = described_class.status_hash(
        current: '1.5.0', cache_path: cache_path, now: now,
        fetcher: ->(_url) { raise SocketError, 'offline' }
      )

      expect(hash).to eq(
        current_version: '1.5.0',
        latest_version: '1.5.0',
        update_available: false
      )
    end
  end

  describe '.tool_not_found_message' do
    it 'names the tool and the installed version and advises updating' do
      described_class.check(current: '1.5.0', cache_path: cache_path, now: now, fetcher: ->(_url) { '1.6.0' })

      msg = described_class.tool_not_found_message('codebase_retrieve', current: '1.5.0', cache_path: cache_path)

      expect(msg).to include('codebase_retrieve')
      expect(msg).to include('1.5.0')
      expect(msg).to include('bundle update woods')
      expect(msg).to include('1.6.0') # latest, from cache — no network on this path
    end

    it 'never performs a network fetch (cache-only)' do
      msg = described_class.tool_not_found_message(
        'some_tool', current: '1.5.0', cache_path: cache_path,
                     fetcher: ->(_url) { raise 'must not be called' }
      )

      expect(msg).to include('some_tool')
      expect(msg).to include('bundle update woods')
    end

    it 'still produces guidance when the cache is corrupt (non-object JSON)' do
      File.write(cache_path, '42')

      msg = nil
      expect { msg = described_class.tool_not_found_message('x', current: '1.5.0', cache_path: cache_path) }
        .not_to raise_error
      expect(msg).to include('x').and include('bundle update woods')
    end
  end
end
