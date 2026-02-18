# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/validator_extractor'

RSpec.describe CodebaseIndex::Extractors::ValidatorExtractor, 'fixture specs' do
  include_context 'extractor setup'

  # ── Custom EachValidator ──────────────────────────────────────────────

  describe 'custom EachValidator with regex validation' do
    it 'extracts validator type, attributes, and error messages' do
      path = create_file('app/validators/email_format_validator.rb', <<~RUBY)
        class EmailFormatValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            unless value.match?(/\\A[\\w+\\-.]+@[a-z\\d\\-]+(\\.[a-z\\d\\-]+)*\\.[a-z]+\\z/i)
              record.errors.add(attribute, "is not a valid email address")
            end
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:validator)
      expect(unit.identifier).to eq('EmailFormatValidator')
      expect(unit.metadata[:validator_type]).to eq(:each_validator)
      expect(unit.metadata[:error_messages]).to include('is not a valid email address')
      expect(unit.metadata[:inferred_models]).to include('EmailFormat')
    end
  end

  # ── Full-Model Validator ──────────────────────────────────────────────

  describe 'full-model Validator with multiple error checks' do
    it 'extracts validate method and multiple error messages' do
      path = create_file('app/validators/date_range_validator.rb', <<~RUBY)
        class DateRangeValidator < ActiveModel::Validator
          def validate(record)
            if record.start_date.blank?
              record.errors.add(:start_date, "must be present")
            end

            if record.end_date.present? && record.start_date.present? && record.end_date < record.start_date
              record.errors.add(:end_date, "must be after start date")
            end
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:validator_type]).to eq(:validator)
      expect(unit.metadata[:error_messages]).to include('must be present', 'must be after start date')
      expect(unit.metadata[:validated_attributes]).to include('start_date', 'end_date')
    end
  end

  # ── Edge: Validator with No validate Method ───────────────────────────

  describe 'file with no validate method' do
    it 'returns nil for a class without validator indicators' do
      path = create_file('app/validators/not_a_validator.rb', <<~RUBY)
        class NotAValidator
          def check(value)
            value.present?
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit).to be_nil
    end
  end

  # ── Edge: Namespaced Validator ────────────────────────────────────────

  describe 'namespaced validator' do
    it 'extracts namespace and identifier for deeply nested validator' do
      path = create_file('app/validators/payments/billing/iban_validator.rb', <<~RUBY)
        class Payments::Billing::IbanValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            unless valid_iban?(value)
              record.errors.add(attribute, :invalid_iban)
            end
          end

          private

          def valid_iban?(value)
            value.match?(/\\A[A-Z]{2}\\d{2}[A-Z0-9]{4,30}\\z/)
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('Payments::Billing::IbanValidator')
      expect(unit.namespace).to eq('Payments::Billing')
      expect(unit.metadata[:error_messages]).to include(':invalid_iban')
    end
  end

  # ── Validator with Options ────────────────────────────────────────────

  describe 'validator using options hash' do
    it 'extracts options accessed via options[]' do
      path = create_file('app/validators/url_validator.rb', <<~RUBY)
        class UrlValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            schemes = options[:schemes] || %w[http https]
            allow_blank = options[:allow_blank]

            return if allow_blank && value.blank?

            uri = URI.parse(value)
            unless schemes.include?(uri.scheme)
              record.errors.add(attribute, "must use one of: \#{schemes.join(', ')}")
            end
          rescue URI::InvalidURIError
            record.errors.add(attribute, "is not a valid URL")
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit.metadata[:options_used]).to include('schemes', 'allow_blank')
      expect(unit.metadata[:error_messages]).to include('is not a valid URL')
    end
  end

  # ── Validator with Custom Error Class ─────────────────────────────────

  describe 'validator with custom error class' do
    it 'extracts custom error class names' do
      path = create_file('app/validators/strict_format_validator.rb', <<~RUBY)
        class StrictFormatValidator < ActiveModel::EachValidator
          class FormatError < StandardError; end

          def validate_each(record, attribute, value)
            record.errors.add(attribute, "has invalid format") unless value.match?(/\\A[a-z_]+\\z/)
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit.metadata[:custom_errors]).to include('FormatError')
    end
  end

  # ── Validator with Service Dependencies ───────────────────────────────

  describe 'validator with service dependencies' do
    it 'detects service and other validator references' do
      path = create_file('app/validators/domain_validator.rb', <<~RUBY)
        class DomainValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            unless DnsLookupService.resolvable?(value)
              record.errors.add(attribute, "domain does not resolve")
            end

            EmailFormatValidator.new(attributes: [:email]).validate_each(record, attribute, value)
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.map { |d| d[:target] }).to include('DnsLookupService')

      validator_deps = unit.dependencies.select { |d| d[:type] == :validator }
      expect(validator_deps.map { |d| d[:target] }).to include('EmailFormatValidator')
    end
  end

  # ── Source Annotation ─────────────────────────────────────────────────

  describe 'source annotation' do
    it 'includes validator type and attributes in header' do
      path = create_file('app/validators/phone_validator.rb', <<~RUBY)
        class PhoneValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            record.errors.add(attribute, "is not a valid phone number") unless value.match?(/\\d{10}/)
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit.source_code).to include('Validator: PhoneValidator')
      expect(unit.source_code).to include('Type: each_validator')
    end
  end
end
