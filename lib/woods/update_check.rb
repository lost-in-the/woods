# frozen_string_literal: true

require 'json'
require 'time'
require 'tmpdir'
require_relative 'version'
require_relative 'atomic_file'

module Woods
  # Best-effort "is a newer Woods release available?" check.
  #
  # Modeled on grove's background update notifier: it queries RubyGems for the
  # latest published +woods+ version, caches the answer on disk for 24h, and is
  # fully non-fatal — any network, parse, or filesystem failure degrades to
  # "no update signal" rather than raising. It exists so the MCP server can tell
  # an agent (and, through it, the user) that the installed gem is behind, which
  # matters because the distributed guide skills operate against whatever version
  # is installed.
  #
  # Two surfaces consume this:
  #   * {Woods::MCP::Server.build_status} embeds {status_hash} under
  #     +server.update+ so +woods_status+ reports update availability.
  #   * {Woods::MCP::VersionAwareToolDispatch} uses {tool_not_found_message} to
  #     turn a bare "Tool not found" into version-aware, self-healing guidance.
  #
  # Disable entirely with +WOODS_NO_UPDATE_CHECK=1+.
  #
  # @example
  #   Woods::UpdateCheck.status_hash
  #   # => { current_version: "1.5.0", latest_version: "1.6.0", update_available: true }
  module UpdateCheck
    # RubyGems endpoint returning +{ "version": "x.y.z" }+ for the latest release.
    RUBYGEMS_LATEST_URL = 'https://rubygems.org/api/v1/versions/woods/latest.json'
    # How long a successful result is trusted before a re-fetch is attempted.
    CACHE_TTL = 24 * 60 * 60
    # A *failed* probe is cached for a shorter window, so an unreachable or slow
    # RubyGems throttles retries (rather than re-blocking on every call) without
    # hiding a real update for a full day once connectivity returns.
    FAILURE_TTL = 60 * 60
    # Open/read timeout for the (best-effort) network probe, in seconds.
    HTTP_TIMEOUT = 1.5

    module_function

    # Resolve update availability, using the on-disk cache when fresh and
    # otherwise fetching once and caching the result.
    #
    # @param current [String] Installed version (defaults to {Woods::VERSION})
    # @param cache_path [String] Path to the JSON cache file
    # @param ttl [Integer] Cache lifetime in seconds
    # @param now [Time] Injected clock (for deterministic specs)
    # @param fetcher [#call] Callable taking the URL and returning a version
    #   string or nil; injectable for tests
    # @return [Hash] +{ current:, latest:, update_available: }+ (latest may be nil)
    def check(current: Woods::VERSION, cache_path: default_cache_path, ttl: CACHE_TTL,
              now: Time.now, fetcher: method(:fetch_latest_version))
      return result(current, nil) if disabled?

      result(current, cached_or_refreshed_latest(cache_path, ttl, now, fetcher))
    end

    # The +server.update+ sub-hash for +woods_status+. Keys are snake_case to
    # match the rest of the status payload's JSON shape.
    #
    # +latest_version+ reports the newest version this process knows about —
    # the published one when it is ahead of the install, otherwise the
    # installed version itself. Reporting the raw published version here made
    # the payload self-contradictory whenever the installed gem was newer (an
    # unreleased build): +current_version: 2.0.0+ next to +latest_version:
    # 1.6.0+ with +update_available: false+ reads as if the running version is
    # invalid. +update_available+ semantics are unchanged: true only when the
    # published version is strictly newer than the installed one.
    #
    # @return [Hash] +{ current_version:, latest_version:, update_available: }+
    def status_hash(current: Woods::VERSION, **opts)
      r = check(current: current, **opts)
      {
        current_version: r[:current],
        latest_version: newest_known_version(r[:current], r[:latest]),
        update_available: r[:update_available]
      }
    end

    # Version-aware replacement for the MCP layer's bare "Tool not found"
    # message. Cache-only — it never triggers a network fetch, since it runs on
    # an error path that must stay cheap.
    #
    # @param tool_name [String] The unrecognized tool name
    # @param current [String] Installed version
    # @return [String] Guidance an agent can relay to the user
    def tool_not_found_message(tool_name, current: Woods::VERSION, cache_path: default_cache_path, fetcher: nil)
      _ = fetcher # accepted so callers/specs can prove it is never invoked on this path
      latest = disabled? ? nil : read_cache(cache_path)&.fetch('latest', nil)
      msg = "Tool not found: #{tool_name}. This tool is not available in the installed " \
            "Woods v#{current}. It may require a newer release — advise the user to run " \
            '`bundle update woods`, then reconnect the MCP server.'
      msg << " (latest published: #{latest})" if latest && newer?(latest, current)
      msg
    end

    # --- internals -----------------------------------------------------------

    def disabled?
      ENV['WOODS_NO_UPDATE_CHECK'] == '1'
    end

    def result(current, latest)
      { current: current, latest: latest, update_available: latest ? newer?(latest, current) : false }
    end

    # The newest version between the installed gem and the last published one
    # this process knows about. Used by {status_hash} for public reporting;
    # the raw published value stays internal for comparison and caching.
    #
    # @param current [String] installed version
    # @param published [String, nil] last known published version (nil when
    #   the probe failed or the check is disabled)
    # @return [String]
    def newest_known_version(current, published)
      return current unless published && newer?(published, current)

      published
    end

    def newer?(latest, current)
      Gem::Version.new(latest) > Gem::Version.new(current)
    rescue ArgumentError
      false
    end

    # Return the cached latest version when the cache entry is still fresh
    # (a shorter window applies to a previously-failed probe), otherwise fetch
    # once and cache the outcome — success *or* failure.
    #
    # @return [String, nil]
    def cached_or_refreshed_latest(cache_path, ttl, now, fetcher)
      entry = read_cache(cache_path)
      return entry['latest'] if entry && fresh_entry?(entry, ttl, now)

      refresh(cache_path, now, fetcher)
    end

    # A success entry is trusted for +ttl+; a failure entry (nil latest) only
    # for {FAILURE_TTL}.
    def fresh_entry?(entry, ttl, now)
      checked_at = entry['checked_at']
      return false unless checked_at.is_a?(Numeric)

      effective_ttl = entry['latest'] ? ttl : FAILURE_TTL
      (now.to_i - checked_at) < effective_ttl
    end

    # Fetch and cache the outcome. A nil latest (unreachable RubyGems, non-2xx,
    # unparseable body) is cached too, so repeated failures are throttled by
    # {FAILURE_TTL} instead of re-probing on every call.
    #
    # @return [String, nil] the latest version, or nil on failure
    def refresh(cache_path, now, fetcher)
      latest = fetcher.call(RUBYGEMS_LATEST_URL)
      write_cache(cache_path, latest, now)
      latest
    rescue StandardError
      write_cache(cache_path, nil, now)
      nil
    end

    # @return [Hash, nil] the parsed cache entry, or nil if absent, unreadable,
    #   or not a JSON object (guards the "never raise" contract against a
    #   corrupt/tampered cache holding e.g. +[]+ or +42+)
    def read_cache(cache_path)
      return nil unless File.exist?(cache_path)

      parsed = JSON.parse(File.read(cache_path))
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end

    def write_cache(cache_path, latest, now)
      Woods::AtomicFile.write(cache_path, JSON.generate('latest' => latest, 'checked_at' => now.to_i))
    rescue StandardError
      nil
    end

    # Default per-user cache location, honoring XDG, falling back to tmpdir.
    def default_cache_path
      base = ENV.fetch('XDG_CACHE_HOME', nil)
      base = File.join(Dir.home, '.cache') if base.nil? || base.empty?
      File.join(base, 'woods', 'update_check.json')
    rescue StandardError
      File.join(Dir.tmpdir, 'woods-update-check.json')
    end

    # Best-effort RubyGems probe. Kept tiny and self-contained so the module has
    # no non-stdlib dependencies.
    #
    # @return [String, nil] latest version string, or nil on any failure
    def fetch_latest_version(url)
      require 'net/http'
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      version = JSON.parse(response.body)['version']
      version if version.is_a?(String) && !version.empty?
    rescue StandardError
      nil
    end
  end
end
