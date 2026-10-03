# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extracted_unit'
require 'woods/source_line_map'

RSpec.describe Woods::SourceLineMap do
  let(:original) do
    <<~RUBY
      # frozen_string_literal: true

      class LedgersController < ApplicationController
        include LedgerBehavior

        def create
          Ledger.post!(params)
        end
      end
    RUBY
  end

  # The shape the controller extractor writes: a routes and filters header,
  # then the source with a commented concern block after the class line.
  let(:composite) do
    <<~RUBY
      # ╔══════════════════════╗
      # ║ Routes               ║
      # ╚══════════════════════╝
      #
      #   POST /ledgers → #create
      #

      # frozen_string_literal: true

      class LedgersController < ApplicationController

      # ┌──────────────────────┐
      # │ Included from: LedgerBehavior
      # └──────────────────────┘
        # module LedgerBehavior
        #   def reverse
        #     Ledger.reverse!(params)
        #   end
        # end
      # ─────── End LedgerBehavior ───────

        include LedgerBehavior

        def create
          Ledger.post!(params)
        end
      end
    RUBY
  end

  def line_of(text, needle)
    text.lines.index { |l| l.include?(needle) } + 1
  end

  describe '.build' do
    it 'is nil when the source was not annotated' do
      expect(described_class.build(original, original)).to be_nil
    end

    it 'is nil when the annotated source does not contain the original' do
      expect(described_class.build(original, "# GET /ledgers\nroute :ledgers\n")).to be_nil
    end

    it 'maps every original code line past a header and an inlined concern block' do
      map = described_class.build(original, composite)

      ['class', 'include', 'def create', 'Ledger.post!', 'end'].each do |needle|
        composite_line = composite.lines.rindex { |l| l.include?(needle) && !l.lstrip.start_with?('#') } + 1
        original_line = original.lines.rindex { |l| l.include?(needle) } + 1
        expect(described_class.translate(map, composite_line)).to eq(original_line), needle
      end
    end

    it 'records runs of lines, not one entry per line' do
      expect(described_class.build(original, composite).size).to be <= 3
    end
  end

  describe '.translate' do
    it 'leaves a line alone when there is no map' do
      expect(described_class.translate(nil, 12)).to eq(12)
    end

    it 'has no original line for a line the annotation added' do
      map = described_class.build(original, composite)

      expect(described_class.translate(map, line_of(composite, 'Ledger.reverse!'))).to be_nil
    end

    it 'passes a nil line through' do
      expect(described_class.translate([[1, 1, 3]], nil)).to be_nil
    end
  end

  describe '.record' do
    let(:dir) { Dir.mktmpdir('source_line_map') }
    let(:path) { File.join(dir, 'ledgers_controller.rb') }
    let(:unit) { Woods::ExtractedUnit.new(type: :controller, identifier: 'LedgersController', file_path: path) }

    after { FileUtils.remove_entry(dir) }

    before { File.write(path, original) }

    it 'stores the map in the unit metadata when the source was annotated' do
      unit.source_code = composite

      described_class.record(unit)

      expect(unit.metadata[:source_line_map]).to eq(described_class.build(original, composite))
    end

    it 'stores nothing when the source is the file verbatim' do
      unit.source_code = original

      described_class.record(unit)

      expect(unit.metadata).not_to have_key(:source_line_map)
    end

    it 'drops a map recorded earlier once the source matches the file' do
      unit.metadata[:source_line_map] = [[3, 1, 2]]
      unit.source_code = original

      described_class.record(unit)

      expect(unit.metadata).not_to have_key(:source_line_map)
    end

    it 'stores nothing when the file is missing' do
      unit.file_path = File.join(dir, 'gone.rb')
      unit.source_code = composite

      described_class.record(unit)

      expect(unit.metadata).not_to have_key(:source_line_map)
    end

    it 'stores nothing for a unit with no file' do
      unit.file_path = nil
      unit.source_code = composite

      described_class.record(unit)

      expect(unit.metadata).not_to have_key(:source_line_map)
    end

    it 'reads a file holding multibyte characters under a US-ASCII default' do
      File.write(path, original.sub('# frozen', '# ✓ frozen'))
      unit.source_code = composite.sub('# frozen', '# ✓ frozen')

      expect { described_class.record(unit) }.not_to raise_error
      expect(unit.metadata[:source_line_map]).not_to be_nil
    end
  end
end
