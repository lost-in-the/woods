# frozen_string_literal: true

require 'spec_helper'
require 'woods/source_references/projector'
require 'woods/extractors/lib_extractor'

RSpec.describe Woods::SourceReferences::Projector do
  let(:original) { "class Caller\n  'é'; Target.call; Target.call\nend\n" }
  let(:path) { 'app/models/caller.rb' }
  let(:unit) { { 'type' => 'poro', 'file_path' => path, 'source_code' => original, 'metadata' => {} } }
  let(:references) do
    [8, 21].map do |column|
      { 'file_path' => path, 'line' => 2, 'column' => column, 'length' => 6, 'target' => 'Target',
        'target_type' => 'lib', 'kind' => 'constant', 'confidence' => 'verified' }
    end
  end
  let(:projector) { described_class.new(source_reader: ->(_path) { original }) }

  it 'publishes every occurrence in byte coordinates only for identical original source' do
    expect(projector.call(unit, references)).to eq(references.map { |record| record.except('file_path') })
  end

  it 'projects past a header and commented inlined source using the recorded line map' do
    annotated = "# Target is documentation\nclass Caller\n#   Target.call\n#{original.lines.drop(1).join}"
    unit['source_code'] = annotated
    unit['metadata']['source_line_map'] = Woods::SourceLineMap.build(original, annotated)
    expect(projector.call(unit, references).map { |record| record.values_at('line', 'column', 'length') })
      .to eq([[4, 8, 6], [4, 21, 6]])
  end

  it 'does not infer identity or search a sliced, generated or scrubbed source for matching constants' do
    [original.lines[1], "# generated\n#{original}", original.sub("'é'", "'x'")].each do |source|
      unit['source_code'] = source
      expect(projector.call(unit, references)).to eq([])
    end
  end

  it 'refuses a stale map or a different physical source' do
    unit['source_code'] = "# header\n#{original}"
    unit['metadata']['source_line_map'] = [[3, 1, 3]]
    expect(projector.call(unit, references)).to eq([])
    unit['source_code'] = original
    expect(projector.call(unit.merge('file_path' => 'app/models/other.rb'), references)).to eq([])
  end

  it 'refuses spans that cross an inserted annotation or exceed the source bounds' do
    source = "class Caller\n  Space::\n    Target.call\nend\n"
    unit['source_code'] = source.sub('    Target', "# inlined comment\n    Target")
    unit['metadata']['source_line_map'] = Woods::SourceLineMap.build(source, unit['source_code'])
    multiline = references.first.merge('column' => 2, 'length' => 18)
    mapper = described_class.new(source_reader: ->(_path) { source })
    expect(mapper.call(unit, [multiline])).to eq([])
    unit['source_code'] = original
    expect(projector.call(unit, [references.first.merge('length' => 1_000)])).to eq([])
  end

  context 'with validated library contributors' do
    include_context 'extractor setup'

    it 'uses exact contributor ranges and never maps a generated separator or a wrong original' do
      first = "module RefParts\n  FirstTarget.call\nend\n"
      second = "module RefParts\n  SecondTarget.call\nend\n"
      create_file('lib/first/ref_parts.rb', first)
      create_file('lib/second/ref_parts.rb', second)
      aggregate = Woods::Extractors::LibExtractor.new.extract_all.first
      data = JSON.parse(JSON.generate(aggregate.to_h))
      originals = { 'lib/first/ref_parts.rb' => first, 'lib/second/ref_parts.rb' => second }
      mapper = described_class.new(source_reader: ->(source_path) { originals.fetch(source_path) })
      raw = originals.keys.map do |source_path|
        references.first.merge('file_path' => source_path, 'column' => 2, 'length' => 11)
      end
      projected = mapper.call(data, raw.reverse)
      expect(projected.map { |record| record['line'] })
        .to eq(Woods::SourceContributors.records(data).map { |record| record['published_start_line'] + 1 })
      originals['lib/second/ref_parts.rb'] = first
      expect(mapper.call(data, raw).size).to eq(1)
      data['metadata']['source_contributors'].last['source_sha256'] = '0' * 64
      expect { mapper.call(data, raw) }.to raise_error(Woods::SourceContributors::Invalid)
    end
  end
end
