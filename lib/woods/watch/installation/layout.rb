# frozen_string_literal: true

require 'pathname'
require_relative '../../agent_configuration/document'

module Woods
  module Watch
    class Installation
      # Absolute paths are transient apply state; receipts retain only relative paths.
      class Layout
        RECEIPT = '.woods-watch.json'
        WRAPPER = 'bin/woods-watch'
        PUMA = 'config/puma.rb'
        PROCFILE = /\AProcfile(?:\.[a-zA-Z0-9_-]+)?\z/

        attr_reader :root

        # @param root [String] canonical application root
        # @param procfile [String] selected root-level Procfile
        def initialize(root, procfile)
          @root = root
          @procfile = procfile
          @extra_paths = []
        end

        # @param path [String] portable target path
        # @return [String] checked absolute path
        def absolute(path)
          unless [RECEIPT, WRAPPER, PUMA].include?(path) || (path.is_a?(String) && PROCFILE.match?(path))
            raise Conflict, "Unsupported watcher installation target: #{path.inspect}"
          end

          File.join(root, path)
        end

        # @param paths [Array<String>] prior owned paths read from the receipt
        # @return [void]
        def include_previous(paths)
          @extra_paths = paths.map { |path| absolute(path) }
        end

        # @return [Array<String>] exact allowed write set
        def allowed_paths
          ([RECEIPT, WRAPPER, PUMA, @procfile].map { |path| absolute(path) } + @extra_paths).uniq
        end

        # @return [String] local journal stem, separate from the portable receipt
        def receipt_path
          File.join(root, 'tmp', 'woods-watch-install', 'transaction')
        end

        # @return [Array<String>] local serialization lock
        def lock_paths
          ["#{receipt_path}.lock"]
        end

        # @return [Hash] transient preview identity, never committed to the receipt
        def identity
          { 'kind' => 'woods-watch-installation', 'root' => root, 'procfile' => @procfile }
        end

        # @param path [String] portable target path
        # @return [Woods::AgentConfiguration::Document]
        def document(path)
          Woods::AgentConfiguration::Document.new(absolute(path))
        end
      end
    end
  end
end
