# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/report'

RSpec.describe Woods::Impact::Endpoint::SharedParse do
  subject(:parse) { described_class.new }

  def unit(at, source: 'class A; end', metadata: { 'extracted_at' => 'nested' })
    { 'type' => 'model', 'identifier' => 'A', 'source_code' => source, 'metadata' => metadata,
      'dependencies' => [], 'extracted_at' => at, 'source_hash' => Digest::SHA256.hexdigest(source) }
  end

  %w[pretty_generate generate].each do |writer|
    context "with #{writer} unit files" do
      def file(data) = JSON.public_send(writer, data)

      let(:writer) { writer }

      it 'shares one frozen parse between files that differ only in their extraction time' do
        head = parse.remember(file(unit('2026-01-02T00:00:00+00:00')))
        base = parse.reuse(file(unit('2026-01-01T00:00:00+00:00')))
        expect(base).to equal(head)
        expect(head).to be_frozen.and(include('extracted_at' => '2026-01-02T00:00:00+00:00'))
        expect(head['metadata']).to be_frozen
      end

      it 'parses a file that differs anywhere else on its own' do
        parse.remember(file(unit('2026-01-02T00:00:00+00:00')))
        base = parse.reuse(file(unit('2026-01-01T00:00:00+00:00', source: 'class A; def b; end; end')))
        expect(base['source_code']).to eq('class A; def b; end; end')
      end

      it 'masks only the top-level extraction time, never a nested one' do
        parse.remember(file(unit('same', metadata: { 'extracted_at' => 'later' })))
        base = parse.reuse(file(unit('same', metadata: { 'extracted_at' => 'earlier' })))
        expect(base.dig('metadata', 'extracted_at')).to eq('earlier')
      end
    end
  end

  it 'masks the shape the extractor writes, pretty or compact' do
    data = Woods::ExtractedUnit.new(type: :model, identifier: 'A', file_path: 'app/models/a.rb')
    data.source_code = 'class A; end'
    %i[pretty_generate generate].each do |writer|
      head = parse.remember(JSON.public_send(writer, data.to_h))
      expect(parse.reuse(JSON.public_send(writer, data.to_h.merge(extracted_at: 'earlier')))).to equal(head)
    end
  end

  it 'parses files of another shape without masking anything' do
    head = { 'type' => 'model', 'identifier' => 'A', 'extracted_at' => 'later' }
    parse.remember(JSON.generate(head))
    expect(parse.reuse(JSON.generate(head.merge('extracted_at' => 'earlier')))['extracted_at']).to eq('earlier')
  end
end
