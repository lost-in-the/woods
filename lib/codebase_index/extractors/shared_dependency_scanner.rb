# frozen_string_literal: true

require_relative '../model_name_cache'

module CodebaseIndex
  module Extractors
    # Common dependency scanning patterns shared across extractors.
    #
    # Most extractors scan source code for the same four dependency types:
    # model references (via ModelNameCache), service objects, background jobs,
    # and mailers. This module centralizes those scanning patterns.
    #
    # Individual scan methods accept an optional +:via+ parameter so
    # extractors can customize the relationship label (e.g., +:serialization+
    # instead of the default +:code_reference+).
    #
    # @example
    #   class FooExtractor
    #     include SharedDependencyScanner
    #
    #     def extract_dependencies(source)
    #       deps = scan_common_dependencies(source)
    #       deps << { type: :custom, target: "Bar", via: :special }
    #       deps.uniq { |d| [d[:type], d[:target]] }
    #     end
    #   end
    #
    module SharedDependencyScanner
      # Scan for ActiveRecord model references using the precomputed regex.
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def scan_model_dependencies(source, via: :code_reference)
        source.scan(ModelNameCache.model_names_regex).uniq.map do |model_name|
          { type: :model, target: model_name, via: via }
        end
      end

      # Scan for service object references (e.g., FooService.call, FooService::new).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_service_dependencies(source, via: :code_reference)
        source.scan(/(\w+Service)(?:\.|::)/).flatten.uniq.map do |service|
          { type: :service, target: service, via: via }
        end
      end

      # Scan for background job references (e.g., FooJob.perform_later).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_job_dependencies(source, via: :code_reference)
        source.scan(/(\w+Job)\.perform/).flatten.uniq.map do |job|
          { type: :job, target: job, via: via }
        end
      end

      # Scan for mailer references (e.g., UserMailer.welcome_email).
      #
      # @param source [String] Ruby source code to scan
      # @param via [Symbol] Relationship label (default: :code_reference)
      # @return [Array<Hash>] Dependency hashes
      def scan_mailer_dependencies(source, via: :code_reference)
        source.scan(/(\w+Mailer)\./).flatten.uniq.map do |mailer|
          { type: :mailer, target: mailer, via: via }
        end
      end

      # Scan for all common dependency types and return a deduplicated array.
      #
      # Combines model, service, job, and mailer scans. Use this when an
      # extractor needs all four standard dependency types with the default
      # +:code_reference+ via label.
      #
      # @param source [String] Ruby source code to scan
      # @return [Array<Hash>] Deduplicated dependency hashes
      def scan_common_dependencies(source)
        deps = []
        deps.concat(scan_model_dependencies(source))
        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_job_dependencies(source))
        deps.concat(scan_mailer_dependencies(source))
        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
