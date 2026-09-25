# frozen_string_literal: true

require 'spec_helper'
require 'woods/chunking/semantic_chunker'

RSpec.describe Woods::Chunking::MethodChunker do
  {
    singleton_body: <<~RUBY,
      class Callable
        def call
          :instance_marker
        end
        class << self
          def call
            :class_marker
          end
        end
      end
    RUBY
    nested_class: <<~RUBY,
      class Callable
        def call
          :outer_marker
        end
        class Nested
          def call
            :nested_marker
          end
        end
      end
    RUBY
    inlined_override: <<~RUBY
      class Callable
        def call
          :concern_marker
        end
        def call
          :override_marker
        end
      end
    RUBY
  }.each do |shape, source|
    it "retains each repeated method in #{shape} with distinct deterministic keys" do
      unit = Woods::ExtractedUnit.new(type: :service, identifier: 'Callable', file_path: 'app/services/callable.rb')
      unit.source_code = source
      chunks = described_class.new(unit).chunk
      markers = source.scan(/:(\w+_marker)/).flatten

      markers.each do |marker|
        expect(chunks.count { |chunk| chunk.content.include?(marker) }).to eq(1)
      end
      expect(chunks.map(&:identifier).uniq.size).to eq(chunks.size)
      expect(chunks.map(&:identifier)).to eq(described_class.new(unit).chunk.map(&:identifier))
      expect(chunks.map(&:identifier)).to include('Callable#method_call', 'Callable#method_call@2')
    end
  end

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
