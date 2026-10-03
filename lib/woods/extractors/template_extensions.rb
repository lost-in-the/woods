# frozen_string_literal: true

require_relative 'view_template_extractor'

module Woods
  module Extractors
    # Template file extensions shared by the extractors that look for view
    # templates outside {ViewTemplateExtractor}: mailer template discovery,
    # ViewComponent sidecar detection, and the caching scan.
    #
    # Each entry is the engine suffix with its leading dot (`.erb`, not
    # `.html.erb`) so callers can combine it with a format (`.html`, `.text`)
    # or glob on it directly.
    module TemplateExtensions
      # Engines whose template source Woods reads and scans: the bare engine
      # suffix of every {ViewTemplateExtractor::ENGINES} entry, so a newly
      # registered engine reaches these extractors too.
      SCANNED = ViewTemplateExtractor::ENGINES
                .flat_map { |engine| engine.new.extensions }
                .map { |extension| extension[/\.[^.]+\z/] }
                .uniq
                .freeze

      # Engines recognised when probing whether a template file exists.
      # Slim has no Woods engine, so its source is never scanned, but a Slim
      # template still answers "does this mailer action have a template".
      DETECTED = (SCANNED + %w[.slim]).freeze
    end
  end
end
