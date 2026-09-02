# frozen_string_literal: true

require 'json'
require 'pathname'
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

    # The directory a generation's payload artifacts live in.
    #
    # Returns the index root when there is no pointer (an index written flat,
    # which is every index written before payloads existed), when the named
    # directory is gone (a stale pointer — a payload retention pruned), or
    # when the name would escape the index root. A torn or tampered pointer
    # must degrade to the flat layout, never read outside the index; the name
    # is written by Woods and is relative by contract.
    #
    # Every reader of a payload artifact resolves through this, so the pointer
    # is followed identically wherever it is read.
    #
    # @param marker [Marker] the generation to resolve; defaults to the
    #   published one. Pass an already-loaded marker to avoid re-reading, and
    #   to resolve a generation a caller has pinned rather than the current one.
    # @return [Pathname]
    def payload_dir(marker = current)
      name = marker.payload
      return root if name.nil? || name.empty?

      candidate = root.join(name)
      return root unless candidate.directory?
      return root unless within_root?(candidate)

      candidate
    end

    # @return [Pathname] the index directory this generation lives in
    def root
      @root ||= Pathname.new(File.dirname(@path))
    end

    private

    # Does +candidate+ resolve inside the index root?
    #
    # Compared through +realpath+, mirroring
    # {Woods::IndexArtifact#validate_dump_dir!} (B-134). +expand_path+ is
    # textual, so a symlink planted *inside* +payloads/+ and pointing outside
    # the index passed the check while +Pathname#directory?+ happily followed
    # it — aiming every payload reader at an arbitrary directory (CORE-6). An
    # index reached through a symlinked root still resolves, because both
    # sides go through realpath.
    #
    # @param candidate [Pathname] an existing directory
    # @return [Boolean] false when it cannot be resolved at all
    def within_root?(candidate)
      candidate_real = candidate.realpath.to_s
      root_real = root.realpath.to_s
      candidate_real.start_with?("#{root_real}#{File::SEPARATOR}")
    rescue SystemCallError
      false
    end
  end
end
