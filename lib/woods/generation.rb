# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'

require_relative 'atomic_file'

module Woods
  # A monotonic marker for "which version of the index is on disk".
  #
  # The index is a directory of files, so a reader has no cheap way to ask
  # "has this changed since I cached it?" — it would have to stat everything.
  # This is that cheap way: one small file, bumped as the *last* step of any
  # write, holding a counter that only ever increases plus a token that
  # changes whenever the counter does.
  #
  # Two properties matter, and both come from #164's central rule — never
  # advance a cursor over work that didn't land:
  #
  # * **Bumped last.** Callers write the index, then bump. A reader that sees
  #   generation N therefore knows the files for N are already there.
  # * **Not bumped on failure.** A run that raised, or that changed nothing,
  #   leaves the generation alone. Staleness is then honest: the reader keeps
  #   serving N and knows it.
  #
  # The write itself is atomic ({AtomicFile}), so a reader never sees a torn
  # generation file. It can also carry a **payload pointer** — the name of an
  # immutable per-generation directory the payload was published into. When
  # present, the single atomic write of this file is the one commit point for
  # the whole payload: a reader resolves every artifact of a read through the
  # directory this generation names, so it sees one generation whole rather
  # than a mix of a manifest from N+1 next to a unit from N. The pointer is
  # optional — an index written flat (payload files directly under the output
  # directory) carries none, and readers fall back to the output directory.
  #
  # @example Publishing after a successful write
  #   Woods::Generation.new(output_dir: "tmp/woods").bump!(reason: "incremental")
  #   # => #<Generation::Marker number=42 token="9f2c…" reason="incremental">
  #
  class Generation
    FILENAME = 'generation.json'

    # An immutable snapshot of the generation file.
    #
    # @!attribute number
    #   @return [Integer] monotonically increasing, starting at 1
    # @!attribute token
    #   @return [String] opaque; changes on every bump
    # @!attribute updated_at
    #   @return [String, nil] ISO8601 stamp of the bump
    # @!attribute reason
    #   @return [String, nil] what produced this generation
    # @!attribute payload
    #   @return [String, nil] name of the immutable directory this generation's
    #     payload lives in, relative to the output directory. nil for an index
    #     written flat (payload files directly under the output directory).
    Marker = Struct.new(:number, :token, :updated_at, :reason, :payload, keyword_init: true) do
      # @return [Hash] string-keyed, ready to serialize. The +payload+ key is
      #   emitted only when set, so a flat index's generation file is byte-for-
      #   byte what it always was.
      def to_h
        base = { 'number' => number, 'token' => token, 'updated_at' => updated_at, 'reason' => reason }
        base['payload'] = payload if payload
        base
      end
    end

    # Marker returned when no generation file exists yet — an index written
    # before generations existed, or a directory nothing has published to.
    UNPUBLISHED = Marker.new(number: 0, token: nil, updated_at: nil, reason: nil).freeze

    # @param output_dir [String, Pathname] index directory
    # @param clock [#call] returns the ISO8601 stamp for a bump; injectable
    #   so specs don't depend on wall-clock time
    def initialize(output_dir:, clock: -> { Time.now.utc.iso8601 })
      @path = File.join(output_dir.to_s, FILENAME)
      @clock = clock
    end

    # @return [String] absolute path to the generation file
    attr_reader :path

    # The generation currently published.
    #
    # A missing or unreadable file reads as {UNPUBLISHED} rather than raising:
    # a reader asking "what generation is this?" of a directory that has none
    # wants an answer, not an exception.
    #
    # @return [Marker]
    def current
      return UNPUBLISHED unless File.exist?(@path)

      data = JSON.parse(AtomicFile.read(@path))
      Marker.new(
        number: data['number'].to_i,
        token: data['token'],
        updated_at: data['updated_at'],
        reason: data['reason'],
        payload: data['payload']
      )
    rescue JSON::ParserError, SystemCallError
      UNPUBLISHED
    end

    # Advance to the next generation.
    #
    # Call this *after* the index files are written, never before, and never
    # after a run that failed or wrote nothing.
    #
    # @param reason [String, nil] what produced this generation, for humans
    #   reading `woods_status`
    # @param payload [String, nil] name of the immutable directory this
    #   generation's payload was published into, relative to the output
    #   directory. Omit for a flat index; when given, this bump becomes the
    #   single commit point for that whole payload (see the class docs).
    # @return [Marker] the newly published generation
    def bump!(reason: nil, payload: nil)
      marker = Marker.new(
        number: current.number + 1,
        token: SecureRandom.hex(8),
        updated_at: @clock.call,
        reason: reason,
        payload: payload
      )
      AtomicFile.write(@path, JSON.generate(marker.to_h))
      marker
    end

    # Has the published generation moved past the one a caller last saw?
    #
    # Compares the token rather than the number, because the number can
    # collapse: `bump!` is a read-modify-write, so two overlapping writers can
    # publish the same number, and a caller holding one of those two would read
    # "not newer" about a genuinely different index. Any token change means the
    # index was republished, whoever won.
    #
    # @param marker [Marker, nil] the caller's last-seen generation
    # @return [Boolean] true when the caller's view is out of date
    def newer_than?(marker)
      return true if marker.nil?

      published = current
      return published.number > marker.number if published.token.nil? || marker.token.nil?

      published.token != marker.token
    end
  end
end
