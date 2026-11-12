# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods/mcp/server'
require 'woods/mcp/published_lexical_retriever'
require 'woods/filename_utils'

RSpec.describe 'Published compact evidence tools' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-source-evidence') }
  let(:source) do
    prefix = (1..40).map { |i| "def unrelated_#{i}; #{'nil; ' * 25}end\n" }.join
    "class Invoice\n#{prefix}def refund(payment)\n payment.reverse!\nend\nend\n"
  end

  before do
    Woods.configuration = Woods::Configuration.new
    File.write(File.join(index_dir, 'manifest.json'), '{}')
    publish('Invoice', 'model', source)
  end
  after { FileUtils.remove_entry(index_dir) }

  def publish(identifier, type, source)
    dir = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type) }.first
    directory = File.join(index_dir, dir)
    FileUtils.mkdir_p(directory)
    unit = { identifier: identifier, type: type, file_path: 'app/models/invoice.rb', source_code: source }
    File.write(File.join(directory, collision_safe_filename(identifier)), JSON.generate(unit))
    File.write(File.join(directory, '_index.json'), JSON.generate([{ identifier: identifier }]))
  end

  def call_tool(name, **args)
    retriever = Woods::MCP::PublishedLexicalRetriever.new(index_dir: index_dir)
    server = Woods::MCP::Server.build(index_dir: index_dir, retriever: retriever, warmup: false, response_format: :json)
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                           params: { name: name, arguments: args }))
    response = JSON.parse(raw, symbolize_names: true)
    expect(response).not_to have_key(:error)
    response.fetch(:result)
  end

  it 'passes the original retrieval query and returns typed compact evidence inside the closed schema' do
    result = call_tool('codebase_retrieve', query: 'refund payment', evidence: 'compact', budget: 450)
    expect(result[:isError]).not_to be(true)
    text = result[:content].first[:text]
    expect(text).to include("def refund(payment)\n payment.reverse!\nend")
    expect(text.length).to be <= 1800
    data = result[:structuredContent][:data][:sources].first[:evidence]
    expect(data[:owner]).to eq(identifier: 'Invoice', type: 'model')
    expect(data[:generation_status]).to eq('unavailable')
  end

  %w[full compact outline].each do |mode|
    [false, true].each do |scoped|
      it "reports budgeted lexical source counts in #{mode} published retrieval, scoped=#{scoped}" do
        options = scoped ? { source_paths: ['app/models'] } : {}
        [40, 450].each do |budget|
          result = call_tool('codebase_retrieve', query: 'refund', evidence: mode, budget: budget, **options)
          expect(result[:isError]).not_to be(true)
          text = result[:content].first[:text]
          included = text.scan(/^## Invoice \(model\)$/).size
          expect(text).to include("sources included: #{included};", 'candidates considered: 1; candidate limit: 20;')
          expect(text.length).to be <= budget * 4
          expect(result[:structuredContent][:text]).to eq(text)
          expect(result[:structuredContent][:data][:sources].size).to eq(included) if scoped || mode != 'full'
          next unless scoped

          expect(result[:structuredContent][:data][:applied_scope])
            .to include(candidate_count: 1, returned_units: included, outcome: 'matched')
        end
      end
    end
  end

  it 'distinguishes typed collisions and follows a full-evidence SHA guard without changing full lookup' do
    publish('Invoice', 'service', 'class Invoice; def service_call; end; end')
    result = call_tool('lookup', identifier: 'Invoice', type: 'model', evidence: 'compact', query: 'refund',
                                 budget: 400)
    evidence = result[:structuredContent][:data][:evidence]
    pointer = evidence[:full_evidence].dup
    tool = pointer.delete(:tool)
    full = call_tool(tool, **pointer)
    expect(JSON.parse(full[:content].first[:text])['source_code']).to eq(source)
    publish('Invoice', 'model', 'class Invoice; def changed; end; end')
    changed = call_tool(tool, **pointer)
    expect(changed[:isError]).to be(true)
    expect(changed[:_meta]).to include(error_code: 'stale_index', argument: 'source_sha256')
  end

  it 'uses actual mixed-bucket types when resolving full evidence' do
    publish('Gem::Thing', 'gem_source', 'class Gem::Thing; end')
    result = call_tool('lookup', identifier: 'Gem::Thing', type: 'gem_source')
    expect(JSON.parse(result[:content].first[:text])['type']).to eq('gem_source')
    expect(call_tool('lookup', identifier: 'Gem::Thing', type: 'rails_source')[:isError]).to be(true)
  end

  it 'refuses incompatible outline/full controls rather than silently ignoring them' do
    [{ evidence: 'outline', include_source: false }, { evidence: 'compact', sections: ['metadata'] },
     { evidence: 'full', query: 'refund' }, { evidence: 'full', budget: 200 }].each do |options|
      result = call_tool('lookup', identifier: 'Invoice', **options)
      expect(result[:isError]).to be(true)
      expect(result[:_meta]).to include(error_code: 'unsupported_argument', argument: 'evidence')
    end
  end

  describe 'lookup evidence control combinations' do
    let(:hint) do
      'Incompatible controls: evidence: "compact" or "outline" cannot take include_source: false or ' \
        'non-empty sections, and evidence: "full" (the default) cannot take query or budget. ' \
        'Drop the incompatible control, or change evidence.'
    end

    # Truth table: full-only controls (include_source: false, sections) and
    # compact/outline-only controls (query, budget) never mix. include_source:
    # true with compact is the near miss: it asks for nothing compact refuses.
    # An omitted evidence is the implicit case: it means full.
    {
      { evidence: 'full', include_source: false } => :allowed,
      { evidence: 'full', sections: ['metadata'] } => :allowed,
      { evidence: 'compact', query: 'refund', budget: 400 } => :allowed,
      { evidence: 'outline', budget: 400 } => :allowed,
      { evidence: 'compact', include_source: true } => :allowed,
      { evidence: 'compact', include_source: false } => :refused,
      { evidence: 'outline', sections: ['metadata'] } => :refused,
      { evidence: 'full', query: 'refund' } => :refused,
      { evidence: 'full', budget: 200 } => :refused,
      { query: 'refund' } => :refused,
      { budget: 200 } => :refused
    }.each do |options, outcome|
      it "#{outcome} for #{options.inspect}" do
        result = call_tool('lookup', identifier: 'Invoice', **options)

        if outcome == :allowed
          expect(result[:isError]).not_to be(true), result.inspect
        else
          expect(result[:isError]).to be(true)
          expect(result[:_meta]).to eq(error_code: 'unsupported_argument', tool: 'lookup',
                                       argument: 'evidence', hint: hint)
        end
      end
    end

    it 'does not attach the evidence hint to an unrelated lookup refusal' do
      result = call_tool('lookup', identifier: 'Invoice', type: 'no_such_type')

      expect(result[:isError]).to be(true)
      expect(result[:_meta]).to include(argument: 'type')
      expect(result[:_meta][:hint]).not_to eq(hint)
    end
  end

  # The rule: a compact or outline lookup states a selected span once. The text
  # names its kind, lexical owner, name and published lines; structured data
  # keeps only what the text cannot state (byte offsets, a receiver, a physical
  # location) under the name that joins the two.
  describe 'lookup evidence states each selected span once' do
    def lookup_evidence(format, **args)
      server = Woods::MCP::Server.build(index_dir: index_dir, warmup: false, response_format: format)
      raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                                             params: { name: 'lookup', arguments: { identifier: 'Invoice', **args } }))
      JSON.parse(raw, symbolize_names: true).fetch(:result)
    end

    def sent_chars(result)
      result[:content].sum { |part| part[:text].length } + JSON.generate(result[:structuredContent]).length
    end

    %i[markdown json].each do |format|
      %w[outline compact].each do |mode|
        it "keeps span facts the text states out of #{mode} structured data (#{format})" do
          result = lookup_evidence(format, evidence: mode, budget: 2000)
          text = result[:content].first[:text]
          evidence = result[:structuredContent][:data][:evidence]
          spans = evidence[:spans]

          expect(spans.size).to be > 5
          spans.each do |span|
            expect(span.keys - %i[name start_byte end_byte receiver physical_location]).to be_empty
            expect(span).not_to have_key(:receiver)
            expect(text).to match(/^instance_method Invoice #{span[:name]}; published lines \d+-\d+$/)
            expect(source.byteslice(span[:start_byte]...span[:end_byte])).to start_with("def #{span[:name]}")
          end
          expect(result[:structuredContent][:text]).to eq(text)
        end

        it "keeps unit-level provenance in #{mode} structured data (#{format})" do
          evidence = lookup_evidence(format, evidence: mode, budget: 2000)[:structuredContent][:data][:evidence]

          expect(evidence).to include(
            mode: mode, coordinate_system: 'published_unit', owner: { identifier: 'Invoice', type: 'model' },
            source_sha256: Digest::SHA256.hexdigest(source), generation_status: 'unavailable',
            source_path: 'app/models/invoice.rb', source_complete: false
          )
          expect(evidence[:omitted_spans]).to eq(41 - evidence[:spans].size)
          expect(evidence[:full_evidence]).to include(tool: 'lookup', evidence: 'full')
        end
      end

      it "sends a smaller outline than the full per-span records did (#{format})" do
        result = lookup_evidence(format, evidence: 'outline', budget: 2000)
        spans = result[:structuredContent][:data][:evidence][:spans]

        expect(spans.size).to eq(41)
        expect(JSON.generate(spans).length).to be < result[:content].first[:text].length
        expect(sent_chars(result)).to be < 9_500
      end
    end

    it 'keeps a receiver, which the text does not state' do
      publish('Invoice', 'model', "class Invoice
def Other.build; end
end\n")
      spans = lookup_evidence(:json, evidence: 'outline')[:structuredContent][:data][:evidence][:spans]

      expect(spans).to eq([{ name: 'build', start_byte: 14, end_byte: 34, receiver: 'Other' }])
    end

    it 'leaves retrieval evidence records complete' do
      result = call_tool('codebase_retrieve', query: 'refund payment', evidence: 'compact', budget: 450)
      span = result[:structuredContent][:data][:sources].first[:evidence][:spans].first

      expect(span).to include(kind: 'instance_method', name: 'refund', lexical_owner: 'Invoice', start_line: 42)
      expect(span[:sha256]).to eq(Digest::SHA256.hexdigest("def refund(payment)\n payment.reverse!\nend"))
    end
  end

  it 'advertises the additive controls while keeping omitted and explicit full retrieval identical' do
    omitted = call_tool('codebase_retrieve', query: 'refund', budget: 400)
    explicit = call_tool('codebase_retrieve', query: 'refund', budget: 400, evidence: 'full')
    expect(explicit).to eq(omitted)
  end
  it 'refuses a symlinked typed directory before opening an outside unit' do
    original = File.join(index_dir, 'models')
    outside = Dir.mktmpdir('woods-evidence-outside')
    FileUtils.cp_r(Dir.glob(File.join(original, '*')), outside)
    FileUtils.remove_entry(original)
    File.symlink(outside, original)
    reader = Woods::MCP::IndexReader.new(index_dir)
    expect { reader.find_unit('Invoice', type: 'model') }.to raise_error(IOError, /symlink unit directory/)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end
  it 'holds the server pin through lookup read, SHA validation and compact generation attribution' do
    File.write(File.join(index_dir, 'generation.json'), JSON.generate(number: 1))
    server = Woods::MCP::Server.build(index_dir: index_dir, warmup: false, response_format: :json)
    reader = server.instance_variable_get(:@woods_index_reader)
    reloaded = Queue.new
    original = reader.method(:find_unit)
    marker_path = File.join(index_dir, 'generation.json')
    reload_thread = nil
    reader.define_singleton_method(:find_unit) do |identifier, **options|
      result = original.call(identifier, **options)
      File.write(marker_path, JSON.generate(number: 2))
      reload_thread = Thread.new do
        reader.with_exclusive_reload { reloaded << true }
      end
      Timeout.timeout(5) { Thread.pass until reader.instance_variable_get(:@exclusive_waiters).positive? }
      raise 'reload completed inside lookup' unless reloaded.empty?

      result
    end
    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                            params: { name: 'lookup', arguments: { identifier: 'Invoice', type: 'model',
                                                                   evidence: 'compact', query: 'refund', budget: 500,
                                                                   source_sha256: Digest::SHA256.hexdigest(source) } })
    result = JSON.parse(server.handle_json(request))
    expect(result.dig('result', 'structuredContent', 'data', 'evidence', 'generation')).to eq(1)
    Timeout.timeout(5) { reload_thread.join }
    expect(reader.loaded_generation).to eq(2)
  ensure
    reload_thread&.join(5)
  end
end
