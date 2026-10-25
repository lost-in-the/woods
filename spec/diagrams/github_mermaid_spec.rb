# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'zlib'
require 'digest'
require 'woods/mcp/index_reader'
require 'woods/diagrams'

# GitHub draws a ```mermaid block with its own Mermaid build (woods#826). This
# spec parses every text the diagram builders produce over the fixture index,
# every kind at every depth, with that exact build, vendored under
# spec/vendor/github_mermaid for this spec only. A text GitHub would refuse
# fails here instead of in a reviewer's pull request. Needs Node; CI opts in
# with WOODS_RUN_GITHUB_MERMAID=1 in a job that sets it up.
RSpec.describe 'Diagram texts parse with the Mermaid GitHub renders', :github_mermaid do
  include DiagramIndex

  vendor = File.expand_path('../vendor/github_mermaid', __dir__)
  let(:build_path) { File.join(vendor, 'mermaid-11.16.1.min.js.gz') }
  let(:dom_path) { File.join(vendor, 'linkedom-0.18.14.mjs.gz') }
  # SHA-256 of mermaid@11.16.1's unmodified dist/mermaid.min.js (README there).
  let(:build_sha256) { '18327bef70d96fb505fe7287d9f6a7362ebf07ff6576ddfaffb1a06f3e1a2954' }

  # What Mermaid's parser reports for each kind's text.
  let(:detected) do
    { 'neighbourhood' => 'flowchart-v2', 'schema' => 'er', 'lifecycle' => 'sequence', 'impact' => 'flowchart-v2' }
  end

  before { Woods::Diagrams::Cache.clear }

  # @return [Array<Array(String, String, String)>] kind, name, text for every kind, depth and option
  def texts
    (neighbourhood_requests + model_requests).map do |kind, id, options|
      result = Woods::Diagrams.build(diagram_reader, kind: kind, identifier: id, index_dir: diagram_root, **options)
      [kind, "#{kind} #{id} #{options}", result.text]
    end
  end

  def neighbourhood_requests
    %w[Post User Comment NotifyJob AuditJob DigestMailer Taggable].flat_map do |id|
      (1..3).to_a.product(%w[both dependents]).map do |depth, dir|
        ['neighbourhood', id, { depth: depth, direction: dir }]
      end
    end
  end

  def model_requests
    %w[Post User Comment].flat_map do |id|
      lifecycles = (0..2).to_a.product(%w[create update destroy]).map do |depth, event|
        ['lifecycle', id, { depth: depth, event: event }]
      end
      (1..3).map { |depth| ['schema', id, { depth: depth }] } + lifecycles +
        [0, 2, 10].map { |depth| ['impact', id, { depth: depth }] }
    end
  end

  def parse_all(list)
    input = JSON.generate(list.map { |_, name, text| { name: name, text: text } })
    out, err, status = Open3.capture3('node', File.expand_path('../support/github_mermaid_parse.mjs', __dir__),
                                      build_path, dom_path, stdin_data: input)
    raise "node failed: #{err}" unless status.success?

    parsed = JSON.parse(out)
    parsed.merge('results' => parsed['results'].to_h { |r| [r['name'], r] })
  end

  it 'vendors the unmodified 11.16.1 build' do
    expect(Digest::SHA256.hexdigest(Zlib.gunzip(File.binread(build_path)))).to eq(build_sha256)
    expect(parse_all([])['version']).to eq('11.16.1')
  end

  it 'parses every kind at every depth as the diagram type it declares' do
    list = texts
    expect(list.map(&:last)).to all(be_a(String))
    results = parse_all(list)['results']
    failures = list.filter_map do |kind, name, _|
      r = results.fetch(name)
      "#{name}: #{r['error'] || "parsed as #{r['detected']}"}" unless r['ok'] && r['detected'] == detected[kind]
    end
    expect(failures).to be_empty, failures.join("\n")
  end

  it 'still rejects a broken text, so a pass means something' do
    results = parse_all([['x', 'broken', "sequenceDiagram\n  A->>"]])['results']
    expect(results.dig('broken', 'ok')).to be(false)
  end
end
