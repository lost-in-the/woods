# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/source_line_map'
require 'woods/file_lines'
require 'woods/method_table'
require 'woods/callback_sites'
require 'woods/extractors/test_examples'

# Lines that leave the server for a reader carry the file's own line beside
# the annotated one: a header Woods prepends and a concern block it inlines
# shift every annotated line, and a reader opening the file needs the file's.
RSpec.describe Woods::FileLines do
  let(:file) do
    <<~RUBY
      class Invoice < ApplicationRecord
        before_save :stamp

        def total
          lines.sum(&:amount)
        end

        private

        def stamp; end
      end
    RUBY
  end

  let(:concern_file) do
    <<~RUBY
      module Billing
        module Rounding
          extend ActiveSupport::Concern

          def rounded_total
            total.round(2)
          end
        end
      end
    RUBY
  end

  let(:header) { "# == Schema Information\n#\n# Table name: invoices\n#\n\n" }

  def concern_block(name, code)
    body = code.lines.map { |line| "  # #{line.rstrip}" }.join("\n")
    "# ┌─────────────────────────────────────────────────────────────────────┐\n" \
      "# │ Included from: #{name.ljust(54)}│\n" \
      "# └─────────────────────────────────────────────────────────────────────┘\n" \
      "#{body}\n" \
      "# ─────────────────────────── End #{name} ───────────────────────────\n"
  end

  def model(annotated)
    Woods::ExtractedUnit.new(type: :model, identifier: 'Invoice', file_path: 'app/models/invoice.rb').tap do |unit|
      unit.source_code = annotated
      map = Woods::SourceLineMap.build(file, annotated)
      unit.metadata[:source_line_map] = map if map
    end
  end

  def file_line_of(text, needle)
    text.lines.index { |line| line.include?(needle) } + 1
  end

  def method_named(unit, name)
    unit.metadata[:methods].find { |entry| entry['name'] == name }
  end

  it 'gives every method the line its def is on in the file, under a header (one-run map)' do
    unit = model(header + file)
    expect(unit.metadata[:source_line_map].size).to eq(1)

    Woods::MethodTable.record(unit)

    %w[total stamp].each do |name|
      entry = method_named(unit, name)
      expect(entry['file_line']).to eq(file_line_of(file, "def #{name}"))
      expect(entry['line']).to eq(entry['file_line'] + 5)
      expect(entry).not_to have_key('file_unit')
    end
  end

  it 'maps a method after an inlined concern block back to the file, and a concern method into its own file' do
    class_line, rest = file.split("\n", 2)
    annotated = "#{header}#{class_line}\n\n#{concern_block('Billing::Rounding', concern_file)}\n#{rest}"
    unit = model(annotated)
    expect(unit.metadata[:source_line_map].size).to be > 1

    Woods::MethodTable.record(unit)

    total = method_named(unit, 'total')
    expect(total['file_line']).to eq(file_line_of(file, 'def total'))
    expect(total['file_end_line']).to eq(file_line_of(file, 'def total') + 2)
    expect(total['line']).not_to eq(total['file_line'])

    rounded = method_named(unit, 'rounded_total')
    expect(rounded['owner']).to eq('Billing::Rounding')
    expect(rounded['file_unit']).to eq('Billing::Rounding')
    expect(rounded['file_line']).to eq(file_line_of(concern_file, 'def rounded_total'))
    expect(rounded['file_end_line']).to eq(file_line_of(concern_file, 'def rounded_total') + 2)
  end

  it 'reports file_line equal to line when the source is the file verbatim (no map)' do
    unit = model(file)
    expect(unit.metadata).not_to have_key(:source_line_map)

    Woods::MethodTable.record(unit)

    expect(unit.metadata[:methods]).to all(satisfy { |entry| entry['file_line'] == entry['line'] })
  end

  it 'gives a callback declaration its file line' do
    unit = model(header + file)
    unit.metadata[:callbacks] = [{ type: :before_save, filter: 'stamp' }]

    Woods::CallbackSites.record(unit)

    expect(unit.metadata[:callbacks].first[:declaration])
      .to include('file_line' => file_line_of(file, 'before_save :stamp'),
                  'line' => file_line_of(file, 'before_save') + 5)
  end

  it 'reports no file line for a line Woods added' do
    unit = model(header + file)
    locator = described_class.for(unit)

    expect(locator.annotate('line' => 1, 'end_line' => 1)).to include('file_line' => nil, 'file_end_line' => nil)
  end

  # A library unit concatenates every file that reopens one module; the map
  # covers only the primary file, so a real method from another contributor
  # has no file line here. It must read as unmapped, not as Woods' own text.
  it 'leaves a method from a secondary library contributor without a file line' do
    primary = "module Util\n  def first; end\nend\n"
    secondary = "module Util\n  def second; end\nend\n"
    published = "#{primary}\n# Library contributor: lib/util/second.rb\n#{secondary}"
    unit = Woods::ExtractedUnit.new(type: :lib, identifier: 'Util', file_path: 'lib/util.rb').tap do |lib|
      lib.source_code = published
      map = Woods::SourceLineMap.build(primary, published)
      lib.metadata[:source_line_map] = map if map
    end

    Woods::MethodTable.record(unit)

    expect(method_named(unit, 'first')['file_line']).to eq(2)
    second = method_named(unit, 'second')
    expect(second['line']).to eq(file_line_of(published, 'def second'))
    expect(second['file_line']).to be_nil
  end

  it 'gives test examples their file lines' do
    spec_file = "RSpec.describe Invoice do\n  it 'totals' do\n  end\nend\n"
    unit = Woods::ExtractedUnit.new(type: :test_mapping, identifier: 'spec/models/invoice_spec.rb',
                                    file_path: 'spec/models/invoice_spec.rb').tap do |test_unit|
      test_unit.source_code = spec_file
      test_unit.metadata[:test_framework] = :rspec
    end

    Woods::Extractors::TestExamples.record(unit)

    example = unit.metadata[:examples].find { |entry| entry['line'] == 2 }
    expect(example).to include('file_line' => 2, 'file_end_line' => 3)
  end
end
