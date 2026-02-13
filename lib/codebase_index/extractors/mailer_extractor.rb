# frozen_string_literal: true

require 'digest'
require_relative 'ast_source_extraction'

module CodebaseIndex
  module Extractors
    # MailerExtractor handles ActionMailer extraction.
    #
    # Mailers are important for understanding:
    # - What triggers emails (traced via dependencies)
    # - What data flows into emails
    # - Template associations
    #
    # @example
    #   extractor = MailerExtractor.new
    #   units = extractor.extract_all
    #   user_mailer = units.find { |u| u.identifier == "UserMailer" }
    #
    class MailerExtractor
      include AstSourceExtraction

      def initialize
        @mailer_base = defined?(ApplicationMailer) ? ApplicationMailer : ActionMailer::Base
      end

      # Extract all mailers in the application
      #
      # @return [Array<ExtractedUnit>] List of mailer units
      def extract_all
        @mailer_base.descendants.map do |mailer|
          extract_mailer(mailer)
        end.compact
      end

      # Extract a single mailer
      #
      # @param mailer [Class] The mailer class
      # @return [ExtractedUnit] The extracted unit
      def extract_mailer(mailer)
        return nil if mailer.name.nil?
        return nil if mailer == ActionMailer::Base

        file_path = source_file_for(mailer)

        unit = ExtractedUnit.new(
          type: :mailer,
          identifier: mailer.name,
          file_path: file_path
        )

        source = file_path && File.exist?(file_path) ? File.read(file_path) : ''

        unit.namespace = extract_namespace(mailer)
        unit.source_code = annotate_source(source, mailer)
        unit.metadata = extract_metadata(mailer, source)
        unit.dependencies = extract_dependencies(source)

        # Create chunks for each mail action
        unit.chunks = build_action_chunks(mailer, source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract mailer #{mailer.name}: #{e.message}")
        nil
      end

      private

      def source_file_for(mailer)
        if mailer.instance_methods(false).any?
          method = mailer.instance_methods(false).first
          mailer.instance_method(method).source_location&.first
        end || Rails.root.join("app/mailers/#{mailer.name.underscore}.rb").to_s
      rescue StandardError
        Rails.root.join("app/mailers/#{mailer.name.underscore}.rb").to_s
      end

      def extract_namespace(mailer)
        parts = mailer.name.split('::')
        parts.size > 1 ? parts[0..-2].join('::') : nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, mailer)
        actions = mailer.action_methods.to_a
        default_from = begin
          mailer.default[:from]
        rescue StandardError
          nil
        end

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Mailer: #{mailer.name.ljust(60)}║
          # ║ Actions: #{actions.first(5).join(', ').ljust(59)}║
          # ║ Default From: #{(default_from || 'not set').to_s.ljust(54)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(mailer, source)
        actions = mailer.action_methods.to_a

        {
          # Actions (mail methods)
          actions: actions,

          # Default settings
          defaults: extract_defaults(mailer),

          # Delivery configuration
          delivery_method: mailer.delivery_method,

          # Callbacks
          callbacks: extract_callbacks(mailer),

          # Layout
          layout: extract_layout(mailer, source),

          # Helper modules
          helpers: extract_helpers(source),

          # Templates (if discoverable)
          templates: discover_templates(mailer, actions),

          # Metrics
          action_count: actions.size,
          loc: source.lines.count { |l| l.strip.present? && !l.strip.start_with?('#') }
        }
      end

      def extract_defaults(mailer)
        defaults = {}

        begin
          mailer_defaults = mailer.default
          defaults[:from] = mailer_defaults[:from] if mailer_defaults[:from]
          defaults[:reply_to] = mailer_defaults[:reply_to] if mailer_defaults[:reply_to]
          defaults[:cc] = mailer_defaults[:cc] if mailer_defaults[:cc]
          defaults[:bcc] = mailer_defaults[:bcc] if mailer_defaults[:bcc]
        rescue StandardError
          # Defaults not accessible
        end

        defaults
      end

      def extract_callbacks(mailer)
        callbacks = []

        %i[before_action after_action around_action].each do |type|
          mailer.send("_#{type}_callbacks").each do |cb|
            callbacks << {
              type: type,
              filter: cb.filter.to_s,
              options: {
                only: cb.options[:only],
                except: cb.options[:except]
              }.compact
            }
          end
        rescue StandardError
          # Callbacks not accessible
        end

        callbacks
      end

      def extract_layout(mailer, source)
        # From class definition
        return ::Regexp.last_match(1) if source =~ /layout\s+['":](\w+)/

        # From class method
        begin
          mailer._layout
        rescue StandardError
          nil
        end
      end

      def extract_helpers(source)
        helpers = []

        source.scan(/helper\s+[:\s]?(\w+)/) do |helper|
          helpers << helper[0]
        end

        source.scan(/include\s+(\w+Helper)/) do |helper|
          helpers << helper[0]
        end

        helpers.uniq
      end

      def discover_templates(mailer, actions)
        templates = {}
        mailer_path = mailer.name.underscore

        actions.each do |action|
          view_paths = [
            Rails.root.join("app/views/#{mailer_path}/#{action}.html.erb"),
            Rails.root.join("app/views/#{mailer_path}/#{action}.text.erb"),
            Rails.root.join("app/views/#{mailer_path}/#{action}.html.slim"),
            Rails.root.join("app/views/#{mailer_path}/#{action}.text.slim")
          ]

          found = view_paths.select { |p| File.exist?(p) }
                            .map { |p| p.to_s.sub(Rails.root.to_s + '/', '') }

          templates[action] = found if found.any?
        end

        templates
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source)
        deps = []

        # Model references (using precomputed regex)
        source.scan(ModelNameCache.model_names_regex).uniq.each do |model_name|
          deps << { type: :model, target: model_name, via: :code_reference }
        end

        # Service references (mailers often call services for data)
        source.scan(/(\w+Service)(?:\.|::)/).flatten.uniq.each do |service|
          deps << { type: :service, target: service, via: :code_reference }
        end

        # URL helpers (indicates what resources emails link to)
        source.scan(/(\w+)_(?:url|path)/).flatten.uniq.each do |route|
          deps << { type: :route, target: route, via: :url_helper }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Action Chunks
      # ──────────────────────────────────────────────────────────────────────

      def build_action_chunks(mailer, _source)
        mailer.action_methods.filter_map do |action|
          action_source = extract_action_source(mailer, action)
          next if action_source.nil? || action_source.strip.empty?

          templates = discover_templates(mailer, [action.to_s])[action.to_s] || []

          chunk_content = <<~ACTION
            # Mailer: #{mailer.name}
            # Action: #{action}
            # Templates: #{templates.any? ? templates.join(', ') : 'none found'}

            #{action_source}
          ACTION

          {
            chunk_type: :mail_action,
            identifier: "#{mailer.name}##{action}",
            content: chunk_content,
            content_hash: Digest::SHA256.hexdigest(chunk_content),
            metadata: {
              parent: mailer.name,
              action: action.to_s,
              templates: templates
            }
          }
        end
      end
    end
  end
end
