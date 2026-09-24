# frozen_string_literal: true

require 'spec_helper'
require 'woods/chunking/semantic_chunker'

RSpec.describe Woods::Chunking::MethodChunker do
  [false, true].each do |reversed|
    %w[call call? call! value= == [] []=].each do |name|
      it "retains #{name} and self.#{name} with stable distinct identities, reverse=#{reversed}" do
        methods = [[name, 'instance_marker'], ["self.#{name}", 'class_marker']]
        methods.reverse! if reversed
        unit = Woods::ExtractedUnit.new(type: :service, identifier: 'Callable', file_path: 'app/services/callable.rb')
        body = methods.map do |method, marker|
          "  def #{method}(value)\n    :#{marker}\n  end\n"
        end.join
        unit.source_code = "class Callable\n#{body}end\n"

        chunks = described_class.new(unit).chunk
        methods.each do |method, marker|
          matching = chunks.select { |chunk| chunk.content.include?(marker) }
          expect(matching.size).to eq(1)
          expect(matching.first.identifier).to eq("Callable#method_#{method}")
        end
        expect(chunks.map(&:identifier).uniq.size).to eq(chunks.size)
      end
    end
  end
end
