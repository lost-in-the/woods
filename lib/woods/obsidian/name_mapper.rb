# frozen_string_literal: true

require 'set'
require 'digest'

module Woods
  module Obsidian
    # Centralizes the identifier -> note-filename mapping for an Obsidian vault.
    #
    # This is the single source of truth for three things that must always
    # agree: the filename a note is written to, the wikilink target that points
    # at it, and the inverse +path -> id+ map shipped in the machine sidecar.
    # Building them in one place means a link can never point at a filename the
    # writer didn't produce.
    #
    # Rules:
    # - Sanitize +::+ to +__+ and every other non +[A-Za-z0-9_-]+ char to +_+,
    #   so the basename is always safe both as a filename and as a wikilink
    #   target (Obsidian's +# | ^ : %%+ link-breaking chars are all removed).
    # - Collisions are resolved **per folder**, case-insensitively (macOS/Windows
    #   fold case): the colliding note gets a short content hash appended. Two
    #   identical basenames in *different* type folders are distinct paths and
    #   need no hash.
    # - The MOC basename +_index+ is reserved in every folder so a (pathological)
    #   unit named +_index+ can never overwrite a folder's index note.
    # - Filenames are capped to 255 bytes, truncated on a UTF-8 char boundary.
    # - The alias (the human-readable display half of a wikilink) keeps the
    #   original identifier, with only the link-structural chars +[ ] |+ replaced.
    #
    # Determinism: ids are processed in sorted order, so the same input always
    # produces the same collision-hash assignments.
    class NameMapper
      MAX_FILENAME_BYTES = 255
      EXTENSION = '.md'
      HASH_SUFFIX_HEX = 8 # hex chars per disambiguation step
      RESERVED_BASENAMES = %w[_index].freeze

      # Basenames Windows refuses to create, with or without an extension.
      # A Ruby class named +Aux+ produced "models/Aux.md", which breaks any
      # vault synced through Windows Obsidian or OneDrive (EXP-9).
      WINDOWS_RESERVED_BASENAMES = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i

      # @param id_to_dir [Hash{String=>String}] map of unit identifier -> type
      #   folder name (e.g. "User" => "models")
      def initialize(id_to_dir)
        @map = {}
        @paths = {}
        build(id_to_dir)
      end

      # @param id [String]
      # @return [String, nil] vault-relative note path ("models/User.md")
      def path_for(id)
        @map[id]&.fetch(:path)
      end

      # @param id [String]
      # @return [String, nil] full wikilink ("[[models/User|User]]") or nil if unknown
      def wikilink(id)
        entry = @map[id]
        return nil unless entry

        "[[#{entry[:target]}|#{entry[:alias]}]]"
      end

      # @return [Hash{String=>String}] inverse path -> id map (sorted)
      def paths_to_ids
        @paths
      end

      private

      def build(id_to_dir)
        taken = Hash.new { |h, dir| h[dir] = Set.new(RESERVED_BASENAMES) }
        id_to_dir.keys.sort.each do |id|
          dir = id_to_dir[id]
          basename = assign_basename(id, taken[dir])
          path = "#{dir}/#{basename}#{EXTENSION}"
          @map[id] = { dir: dir, basename: basename, path: path, target: "#{dir}/#{basename}", alias: alias_for(id) }
          @paths[path] = id
        end
      end

      # Claim a free basename in this folder, case-insensitively.
      #
      # The hashed candidate used to be inserted without being re-checked, so
      # a hash prefix that happened to equal an existing literal basename put
      # two notes at one path — last writer wins, and one id silently vanished
      # from the inverse map (EXP-9). Now the digest slice widens until the
      # candidate is free.
      def assign_basename(id, used)
        candidate = fit(sanitize(id), EXTENSION.bytesize)
        digest = Digest::SHA256.hexdigest(id)
        attempt = 0

        while used.include?(candidate.downcase)
          attempt += 1
          candidate = hashed_basename(id, hash_suffix(digest, attempt))
        end

        used << candidate.downcase
        candidate
      end

      # Widening slices of the digest (8, 16, ... 64 hex chars), then the whole
      # digest plus a counter — so {#assign_basename} terminates even in the
      # (unreachable, ids are unique) case that every slice is taken.
      def hash_suffix(digest, attempt)
        width = attempt * HASH_SUFFIX_HEX
        return digest[0, width] if width <= digest.length

        "#{digest}-#{attempt - (digest.length / HASH_SUFFIX_HEX)}"
      end

      def hashed_basename(id, suffix)
        "#{fit(sanitize(id), EXTENSION.bytesize + 1 + suffix.bytesize)}-#{suffix}"
      end

      def sanitize(id)
        out = id.to_s.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
        return 'unit' if out.empty?

        WINDOWS_RESERVED_BASENAMES.match?(out) ? "_#{out}" : out
      end

      # Replace only the chars that are structural inside a wikilink alias.
      # `#` and `:` are safe in alias display text and are kept for readability.
      def alias_for(id)
        id.to_s.gsub('[', '(').gsub(']', ')').gsub('|', '/')
      end

      # Truncate +str+ so it fits within MAX_FILENAME_BYTES minus +reserve+
      # bytes, never splitting a multibyte character.
      def fit(str, reserve)
        limit = MAX_FILENAME_BYTES - reserve
        return str if str.bytesize <= limit

        out = +''
        str.each_char do |ch|
          break if out.bytesize + ch.bytesize > limit

          out << ch
        end
        out
      end
    end
  end
end
