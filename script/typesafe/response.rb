# frozen_string_literal: true

module WoodsDevelopment
  module TypeSafe
    class InvalidEvidence < StandardError; end

    # Validates recorded Choice/Noul answers without interpreting unknown fields.
    # Score is intentionally unsupported until an experiment uses it.
    module Response
      module_function

      def validate!(request, response)
        check(response.is_a?(Hash) && response['model'] == request.fetch('model'))
        questions = request.fetch('questions')
        answers = response['answers']
        check(answers.is_a?(Hash) && answers.keys.sort == questions.keys.sort)
        questions.each { |id, question| answer!(question, answers.fetch(id)) }
        usage!(response['usage'])
        response
      end

      def answer!(question, answer)
        check(answer.is_a?(Hash) && answer['type'] == question.fetch('type'))
        case question.fetch('type')
        when 'noul' then probability!(answer['noul'])
        when 'choice' then choice!(question, answer)
        else check(false)
        end
      end

      def choice!(question, answer)
        probabilities = answer['probabilities']
        check(probabilities.is_a?(Hash) && probabilities.keys.sort == question.fetch('criteria').keys.sort)
        distribution!(probabilities)
        check(probabilities.key?(answer['choice']))
        check(probabilities.fetch(answer['choice']) + 0.00001 >= probabilities.values.max)
        probability!(answer['confidence'])
      end

      def distribution!(probabilities)
        probabilities.each_value { |value| probability!(value) }
        check((probabilities.values.sum - 1).abs <= 0.00001)
      end

      def usage!(usage)
        check(usage.is_a?(Hash))
        %w[input_tokens output_tokens].each do |key|
          check(usage[key].is_a?(Integer) && usage[key] >= 0)
        end
      end

      def probability!(value)
        check(value.is_a?(Numeric) && value.finite? && value.between?(0, 1))
      end

      def check(condition)
        raise InvalidEvidence, 'Invalid evaluation evidence' unless condition
      end
    end
  end
end
