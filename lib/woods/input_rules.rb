# frozen_string_literal: true

require 'json'
require 'woods/reload_policy'
require 'woods/path_dispatcher'
require 'woods/generation'
require 'woods/atomic_file'

module Woods
  # Shared fresh-process action contract. Loading this class does not boot Rails.
  # Extractor constants are needed only when deriving the dispatcher projection.
  #
  # Declared source roots (`woods-extract --source-root PATH`, recorded as the
  # published manifest's `extra_roots`) are extraction input too: a Ruby file
  # under one is incremental work, exactly like a file under `app/`. Without
  # them a declared-root edit was classified `:ignore` by the launcher, the
  # hook task, the rake task and the plugin predicate, and dropped with no
  # output (F15).
  class InputRules
    # @return [Array<String>] root-relative directories declared as source
    attr_reader :extra_roots

    # The rules for a published index: its manifest's declared roots, or none
    # when the index, the manifest or the field is missing or malformed.
    #
    # @param output_dir [String, Pathname] index root
    # @return [InputRules]
    def self.for_index(output_dir)
      new(extra_roots: declared_roots_of(output_dir))
    end

    # @param output_dir [String, Pathname]
    # @return [Array<String>]
    def self.declared_roots_of(output_dir)
      return [] if output_dir.nil? || output_dir.to_s.empty?

      generation = Generation.new(output_dir: output_dir.to_s)
      manifest = generation.payload_dir.join('source_inputs.json')
      return [] unless manifest.file?

      roots = JSON.parse(AtomicFile.read(manifest))['extra_roots']
      roots.is_a?(Array) ? roots.grep(String).reject(&:empty?).uniq : []
    rescue JSON::ParserError, SystemCallError, IOError, TypeError, EncodingError
      []
    end

    # @param extra_roots [Array<String>] declared source roots, root-relative
    def initialize(extra_roots: [])
      @extra_roots = Array(extra_roots).map { |root| root.to_s.delete_suffix('/') }.reject(&:empty?).uniq
    end

    def action(path, operation: 'update')
      return :full if ReloadPolicy.new.classify(path) == :restart
      return :ignore unless PathDispatcher.new.relevant?(path) || declared_root_ruby?(path)

      # A removed runtime class may no longer be discoverable in a fresh boot.
      # Full extraction also handles the old side of a rename conservatively.
      %w[delete move].include?(operation) ? :full : :incremental
    end

    # @param path [String] root-relative path
    # @return [Boolean] a Ruby file under a declared source root
    def declared_root_ruby?(path)
      path.end_with?('.rb') && @extra_roots.any? { |root| path.start_with?("#{root}/") }
    end

    # @return [String] the roots a path is matched against, for a diagnostic
    def known_roots_summary
      (%w[app/ lib/] + @extra_roots.map { |root| "#{root}/" }).join(', ')
    end
  end
end
