# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'profiles'
require_relative 'response'

module WoodsDevelopment
  module TypeSafe
    # Offline-only first milestone. Labels and provenance are never API inputs.
    class Replay
      CASE_KEYS = %w[id family label complete request request_sha256 response].freeze
      SIGNAL_IDS = (['assessment'] + Profiles::SIGNALS).sort.freeze
      MAX_BYTES = 16 * 1024 * 1024
      ASSESSMENT = JSON.parse(File.read(File.join(__dir__, 'assessment.json'), encoding: 'UTF-8')).freeze

      def self.read(path)
        raise InvalidEvidence, 'Capture too large' if File.size(path) > MAX_BYTES

        bytes = File.read(path, encoding: 'UTF-8')
        Response.check(bytes.valid_encoding?)
        new(JSON.parse(bytes)).report
      end

      def initialize(document)
        validate_encoding!(document)
        Response.check(document.is_a?(Hash) && document.keys.sort == %w[cases schema_version])
        Response.check(document['schema_version'] == 1 && document['cases'].is_a?(Array))
        @cases = document.fetch('cases')
        Response.check(!@cases.empty? && @cases.length <= 150)
        @cases.each { |entry| validate_case!(entry) }
        Response.check(@cases.map { |entry| entry.fetch('id') }.uniq.length == @cases.length)
      end

      def report
        rows = @cases.map { |entry| assess(entry) }
        counts(rows).merge(
          'policy' => Profiles::VERSION, 'intended' => rows.length,
          'raw_false_direct' => false_direct(rows, 'raw'),
          'effective_false_direct' => false_direct(rows, 'effective'),
          'direct_retained' => rows.count { |row| row['label'] == 'direct' && row['effective'] == 'direct' },
          'review_count' => rows.count { |row| %w[review needs_context].include?(row['effective']) },
          'families' => rows.map { |row| row['family'] }.uniq.length, 'rows' => rows
        )
      end

      private

      def counts(rows)
        {
          'completed' => rows.count { |row| row['status'] == 'completed' },
          'errors' => rows.count { |row| row['status'] == 'error' },
          'raw_exact_matches' => rows.count { |row| row['raw'] == row['label'] }
        }
      end

      def false_direct(rows, field)
        rows.count { |row| row[field] == 'direct' && row['label'] != 'direct' }
      end

      def validate_case!(entry)
        Response.check(entry.is_a?(Hash) && entry.keys.sort == CASE_KEYS.sort)
        %w[id family].each { |key| Response.check(entry[key].is_a?(String) && !entry[key].empty?) }
        Response.check(Profiles::LABELS.include?(entry['label']) && [true, false].include?(entry['complete']))
        request = entry.fetch('request')
        validate_request!(request)
        Response.check(Digest::SHA256.hexdigest(JSON.generate(request)) == entry['request_sha256'])
      end

      def validate_request!(request)
        Response.check(request.is_a?(Hash) && request.keys.sort == %w[model questions state])
        Response.check(request['model'].is_a?(String) && !request['model'].empty?)
        validate_state!(request['state'])
        questions = request['questions']
        Response.check(questions.is_a?(Hash) && [%w[assessment], SIGNAL_IDS].include?(questions.keys.sort))
        validate_questions!(questions)
      end

      def validate_state!(state)
        Response.check(state.is_a?(Hash) && state.keys.sort == %w[invariant test_source])
        state.each_value { |value| Response.check(value.is_a?(String) && !value.empty?) }
      end

      def validate_questions!(questions)
        expected = questions.length == 1 ? { 'assessment' => ASSESSMENT } : Profiles.questions(ASSESSMENT)
        Response.check(questions == expected)
      end

      def validate_encoding!(value)
        case value
        when String then validate_string!(value)
        when Hash then value.each { |pair| validate_encoding!(pair) }
        when Array then value.each { |item| validate_encoding!(item) }
        end
      end

      def validate_string!(value)
        Response.check(value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?))
      end

      def assess(entry)
        row = entry.slice('id', 'family', 'label')
        return row.merge('status' => 'error', 'error' => 'missing_response') unless entry['response']

        Response.validate!(entry.fetch('request'), entry.fetch('response'))
        answers = entry.fetch('response').fetch('answers')
        row.merge('status' => 'completed', 'raw' => answers.fetch('assessment').fetch('choice'),
                  'effective' => Profiles.route(answers, complete: entry.fetch('complete')))
      rescue InvalidEvidence, KeyError, TypeError
        row.merge('status' => 'error', 'error' => 'invalid_response')
      end
    end
  end
end
