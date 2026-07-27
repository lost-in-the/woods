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
  # generation file — though the *payload* it points at is still a directory
  # of independently-written files, and closing that gap is separate work.
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
    Marker = Struct.new(:number, :token, :updated_at, :reason, keyword_init: true) do
      # @return [Hash] string-keyed, ready to serialize
      def to_h
        { 'number' => number, 'token' => token, 'updated_at' => updated_at, 'reason' => reason }
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

      data = JSON.parse(File.read(@path))
      Marker.new(
        number: data['number'].to_i,
        token: data['token'],
        updated_at: data['updated_at'],
        reason: data['reason']
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
    # @return [Marker] the newly published generation
    def bump!(reason: nil)
      marker = Marker.new(
        number: current.number + 1,
        token: SecureRandom.hex(8),
        updated_at: @clock.call,
        reason: reason
      )
      AtomicFile.write(@path, JSON.generate(marker.to_h))
      marker
    end

    # Has the published generation moved past the one a caller last saw?
    #
    # @param marker [Marker, nil] the caller's last-seen generation
    # @return [Boolean] true when the caller's view is out of date
    def newer_than?(marker)
      return true if marker.nil?

      current.number > marker.number
    end
  end
end
