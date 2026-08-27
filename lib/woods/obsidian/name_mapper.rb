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
      HASH_SUFFIX_BYTES = 9 # "-" + 8 hex chars
      RESERVED_BASENAMES = %w[_index].freeze

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

      def assign_basename(id, used)
        base = fit(sanitize(id), EXTENSION.bytesize)
        if used.include?(base.downcase)
          base = "#{fit(sanitize(id), EXTENSION.bytesize + HASH_SUFFIX_BYTES)}-#{Digest::SHA256.hexdigest(id)[0, 8]}"
        end
        used << base.downcase
        base
      end

      def sanitize(id)
        out = id.to_s.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
        out.empty? ? 'unit' : out
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
