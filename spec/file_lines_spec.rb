# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/source_line_map'
require 'woods/file_lines'
require 'woods/method_table'
require 'woods/callback_sites'
require 'woods/extractors/test_examples'
require 'woods/extractors/model_extractor'
require 'digest'
require 'fileutils'
require 'tmpdir'

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

  # The extractor's own block builder, so a change to its frame format
  # can't leave this spec passing against a stale copy.
  def concern_block(name, code)
    Woods::Extractors::ModelExtractor.allocate.send(:build_concern_block, [[name, code]])
  end

  around do |example|
    Dir.mktmpdir('woods-file-lines') do |root|
      @root = root
      example.run
    end
  end

  # A unit whose file is on disk, placed the way extraction places it.
  def unit_from_file(annotated, contents: file, type: :model, identifier: 'Invoice', path: 'app/models/invoice.rb')
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), contents)
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: path).tap do |unit|
      unit.source_code = annotated
      yield unit if block_given?
      Woods::SourceLineMap.record(unit, root: @root)
    end
  end

  def model(annotated)
    unit_from_file(annotated)
  end

  # A library unit published from several files, as LibExtractor assembles it.
  def library(primary, secondary)
    published = +''
    records = [['lib/util.rb', primary], ['lib/util/second.rb', secondary]].map do |path, code|
      published << "# Library contributor: #{path}\n"
      start_byte = published.bytesize
      start_line = published.count("\n") + 1
      published << code
      record = { 'file_path' => path, 'source_sha256' => Digest::SHA256.hexdigest(code),
                 'source_start_line' => 1, 'source_end_line' => code.lines.size,
                 'published_start_byte' => start_byte, 'published_end_byte' => published.bytesize,
                 'published_start_line' => start_line, 'published_end_line' => start_line + code.lines.size - 1,
                 'facts' => {} }
      published << "\n\n"
      record
    end
    unit_from_file(published, contents: primary, type: :lib, identifier: 'Util', path: 'lib/util.rb') do |unit|
      unit.metadata[:source_contributors_version] = Woods::SourceContributors::VERSION
      unit.metadata[:source_contributors] = records
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

  # A sliced unit (a nested class, a constant, a generated definition)
  # publishes part of its file, so no map is built; that proves nothing about
  # where the slice sits, and the slice's own lines must not pass as file lines.
  it 'reports no file line for a unit that publishes only a slice of its file' do
    outer = "module Outer\n  VERSION = 1\n\n  class Inner\n    def run; end\n  end\nend\n"
    slice = "# Nested in Outer\nclass Inner\n  def run; end\nend\n"
    unit = unit_from_file(slice, contents: outer, type: :poro, identifier: 'Outer::Inner', path: 'lib/outer.rb')
    expect(unit.metadata).not_to have_key(:source_line_map)

    Woods::MethodTable.record(unit)

    expect(method_named(unit, 'run')).to include('line' => 3, 'file_line' => nil, 'file_end_line' => nil)
  end

  it 'reports no file line when the file cannot be read' do
    unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Invoice', file_path: 'app/models/missing.rb')
    unit.source_code = file
    Woods::SourceLineMap.record(unit, root: @root)

    Woods::MethodTable.record(unit)

    expect(unit.metadata[:methods]).to all(include('file_line' => nil, 'file_end_line' => nil))
  end

  # A library unit concatenates every file that reopens one module. The
  # primary file's lines come from its own contributor fragment, ends
  # included; a real method from another contributor has no file line here
  # (it reads as unmapped, not as Woods' own text).
  it 'places a library unit through its primary contributor fragment only' do
    primary = "module Util\n  def first\n    1\n  end\nend\n"
    secondary = "module Util\n  def second\n    2\n  end\nend\n"
    unit = library(primary, secondary)

    Woods::MethodTable.record(unit)

    expect(method_named(unit, 'first')).to include('file_line' => 2, 'file_end_line' => 4)
    second = method_named(unit, 'second')
    expect(second['line']).to eq(file_line_of(unit.source_code, 'def second'))
    expect(second).to include('file_line' => nil, 'file_end_line' => nil)
  end

  it 'gives test examples their file lines' do
    spec_file = "RSpec.describe Invoice do\n  it 'totals' do\n  end\nend\n"
    unit = unit_from_file(spec_file, contents: spec_file, type: :test_mapping,
                                     identifier: 'spec/models/invoice_spec.rb',
                                     path: 'spec/models/invoice_spec.rb') do |test_unit|
      test_unit.metadata[:test_framework] = :rspec
    end

    Woods::Extractors::TestExamples.record(unit)

    example = unit.metadata[:examples].find { |entry| entry['line'] == 2 }
    expect(example).to include('file_line' => 2, 'file_end_line' => 3)
  end
end
