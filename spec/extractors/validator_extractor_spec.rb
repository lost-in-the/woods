# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractors/validator_extractor'

RSpec.describe CodebaseIndex::Extractors::ValidatorExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers validator files in app/validators/' do
      create_file('app/validators/email_format_validator.rb', <<~RUBY)
        class EmailFormatValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            unless value =~ /\\A[^@]+@[^@]+\\z/
              record.errors.add(attribute, "is not a valid email")
            end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('EmailFormatValidator')
      expect(units.first.type).to eq(:validator)
    end

    it 'discovers files in nested directories' do
      create_file('app/validators/payments/card_number_validator.rb', <<~RUBY)
        class Payments::CardNumberValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            record.errors.add(attribute, "is invalid") unless luhn_valid?(value)
          end

          private

          def luhn_valid?(number)
            true
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('Payments::CardNumberValidator')
      expect(units.first.namespace).to eq('Payments')
    end

    it 'skips non-validator files' do
      create_file('app/validators/validator_helper.rb', <<~RUBY)
        module ValidatorHelper
          def format_error(msg)
            msg.capitalize
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end
  end

  # ── extract_validator_file ───────────────────────────────────────────

  describe '#extract_validator_file' do
    it 'extracts EachValidator metadata' do
      path = create_file('app/validators/email_format_validator.rb', <<~RUBY)
        class EmailFormatValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            unless value =~ /\\A[^@]+@[^@]+\\z/
              record.errors.add(attribute, "is not a valid email")
            end
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:validator)
      expect(unit.identifier).to eq('EmailFormatValidator')
      expect(unit.metadata[:validator_type]).to eq(:each_validator)
      expect(unit.metadata[:error_messages]).to include('is not a valid email')
      expect(unit.metadata[:public_methods]).to include('validate_each')
    end

    it 'extracts Validator (full-model) metadata' do
      path = create_file('app/validators/consistency_validator.rb', <<~RUBY)
        class ConsistencyValidator < ActiveModel::Validator
          def validate(record)
            if record.start_date > record.end_date
              record.errors.add(:base, "start date must be before end date")
            end
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:validator_type]).to eq(:validator)
      expect(unit.metadata[:error_messages]).to include('start date must be before end date')
    end

    it 'detects validators by method signature when no explicit inheritance' do
      path = create_file('app/validators/phone_validator.rb', <<~RUBY)
        class PhoneValidator
          def validate_each(record, attribute, value)
            record.errors.add(attribute, :invalid) unless value.match?(/\\d{10}/)
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit).not_to be_nil
      expect(unit.metadata[:validator_type]).to eq(:each_validator)
    end

    it 'annotates source with header' do
      path = create_file('app/validators/email_format_validator.rb', <<~RUBY)
        class EmailFormatValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            record.errors.add(attribute, "invalid")
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit.source_code).to include('Validator: EmailFormatValidator')
      expect(unit.source_code).to include('Type: each_validator')
    end

    it 'returns nil for non-validator files' do
      path = create_file('app/validators/utility.rb', <<~RUBY)
        class Utility
          def self.format(data)
            data.to_json
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit).to be_nil
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_validator_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'extracts error symbol messages' do
      path = create_file('app/validators/presence_validator.rb', <<~RUBY)
        class PresenceValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            record.errors.add(attribute, :blank) if value.blank?
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit.metadata[:error_messages]).to include(':blank')
    end

    it 'extracts options used by the validator' do
      path = create_file('app/validators/length_range_validator.rb', <<~RUBY)
        class LengthRangeValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            min = options[:minimum] || 0
            max = options[:maximum] || 255
            unless value.length.between?(min, max)
              record.errors.add(attribute, "must be between \#{min} and \#{max} characters")
            end
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit.metadata[:options_used]).to include('minimum', 'maximum')
    end

    it 'infers conceptual domain from class name' do
      path = create_file('app/validators/email_format_validator.rb', <<~RUBY)
        class EmailFormatValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            record.errors.add(attribute, "invalid")
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      expect(unit.metadata[:inferred_models]).to include('EmailFormat')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_validator_file,
                    'app/validators/uniqueness_validator.rb',
                    <<~RUBY
                      class UniquenessValidator < ActiveModel::EachValidator
                        def validate_each(record, attribute, value)
                          ValidationService.call(record, attribute)
                        end
                      end
                    RUBY

    it 'detects service dependencies' do
      path = create_file('app/validators/fraud_check_validator.rb', <<~RUBY)
        class FraudCheckValidator < ActiveModel::EachValidator
          def validate_each(record, attribute, value)
            result = FraudDetectionService.call(value)
            record.errors.add(attribute, "flagged for fraud") unless result.clean?
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(service_deps.first[:target]).to eq('FraudDetectionService')
      expect(service_deps.first[:via]).to eq(:code_reference)
    end

    it 'detects validator-to-validator dependencies' do
      path = create_file('app/validators/composite_validator.rb', <<~RUBY)
        class CompositeValidator < ActiveModel::Validator
          def validate(record)
            EmailFormatValidator.new(attributes: [:email]).validate_each(record, :email, record.email)
          end
        end
      RUBY

      unit = described_class.new.extract_validator_file(path)
      validator_deps = unit.dependencies.select { |d| d[:type] == :validator }
      expect(validator_deps.first[:target]).to eq('EmailFormatValidator')
    end
  end
end
