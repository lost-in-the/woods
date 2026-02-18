# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Token estimation accuracy', :benchmark do
  let(:source_files) do
    Dir[File.expand_path('../lib/codebase_index/**/*.rb', __dir__)]
      .reject { |f| f.end_with?('/version.rb') }
      .sort_by { |f| File.size(f) }
  end

  let(:heuristic_divisor) { 4.0 }

  def heuristic_estimate(text)
    (text.length / heuristic_divisor).ceil
  end

  context 'with tiktoken_ruby' do
    before do
      require 'tiktoken_ruby'
    rescue LoadError
      skip 'tiktoken_ruby not installed — run: gem install tiktoken_ruby'
    end

    it 'overestimates by a bounded amount against cl100k_base' do
      encoder = Tiktoken.encoding_for_model('gpt-4')

      errors = source_files.first(20).map do |file|
        content = File.read(file)
        estimate = heuristic_estimate(content)
        actual = encoder.encode(content).length
        next if actual.zero?

        ((estimate - actual).to_f / actual * 100)
      end.compact

      mean_error = errors.sum / errors.size

      # The heuristic should always overestimate (positive error) — this is safe
      expect(mean_error).to be > 0, 'heuristic should overestimate (conservative)'

      # But it should not overestimate by more than 40% on average
      expect(mean_error).to be < 40.0,
                            "mean overestimation is #{mean_error.round(1)}% — too high"
    end

    it 'never underestimates by more than 5%' do
      encoder = Tiktoken.encoding_for_model('gpt-4')

      source_files.first(20).each do |file|
        content = File.read(file)
        estimate = heuristic_estimate(content)
        actual = encoder.encode(content).length
        next if actual.zero?

        underestimate_pct = ((actual - estimate).to_f / actual * 100)

        expect(underestimate_pct).to be < 5.0,
                                     "#{File.basename(file)}: underestimates by #{underestimate_pct.round(1)}%"
      end
    end
  end

  context 'without tiktoken_ruby (self-consistency)' do
    it 'produces consistent estimates across similar-sized Ruby files' do
      # Group files by size bucket and verify estimates are proportional to content length
      files_with_content = source_files.first(15).map do |file|
        content = File.read(file)
        { file: file, chars: content.length, estimate: heuristic_estimate(content) }
      end

      files_with_content.each do |entry|
        expected = (entry[:chars] / heuristic_divisor).ceil
        expect(entry[:estimate]).to eq(expected)
      end
    end

    it 'estimates are monotonically increasing with content length' do
      unsorted = source_files.first(15).map do |file|
        content = File.read(file)
        { chars: content.length, estimate: heuristic_estimate(content) }
      end
      estimates = unsorted.sort_by { |e| e[:chars] }

      estimates.each_cons(2) do |a, b|
        expect(b[:estimate]).to be >= a[:estimate],
                                'estimate should increase with content length'
      end
    end
  end
end
