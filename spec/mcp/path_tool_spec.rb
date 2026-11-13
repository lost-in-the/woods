# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/mcp/server'

# `path` answers "how does A reach B" from the published graph. A refusal says
# what to pass instead, and an answer of no path says whether the search ran
# to its end: an agent must never read "stopped by a bound" as "not connected".
RSpec.describe 'MCP path tool' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:index_dir) { Dir.mktmpdir('woods-path-tool') }
  let(:coverage_notice) { Woods::MCP::TraversalResponse::COVERAGE[:notice] }

  before do
    FileUtils.cp_r("#{fixture_dir}/.", index_dir)
    File.write(File.join(index_dir, 'dependency_graph.json'), JSON.generate(graph.to_h))
  end

  after { FileUtils.remove_entry(index_dir) }

  def unit(type, identifier, *dependencies)
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "/app/#{identifier}.rb").tap do |unit|
      unit.dependencies = dependencies.map do |dependency|
        dependency.is_a?(Hash) ? dependency : { target: dependency, via: :code_reference }
      end
    end
  end

  let(:graph) do
    Woods::DependencyGraph.new.tap do |graph|
      [unit(:controller, 'OrdersController', 'CheckoutService', 'docs/checkout.md'),
       unit(:service, 'CheckoutService', { target: 'PaymentGateway', via: :code_reference },
            { target: 'PaymentGateway', via: :job_enqueue }),
       unit(:service, 'PaymentGateway', 'Post'),
       unit(:model, 'Post'),
       unit(:model, 'Comment', { target: 'Post', via: :belongs_to }),
       unit(:doc, 'docs/checkout.md', 'Comment'),
       unit(:database_view, 'reports', 'Post'),
       unit(:factory, 'reports', 'Comment')].each { |unit| graph.register(unit) }
    end
  end

  def build(format = :markdown)
    Woods::MCP::Server.build(index_dir: index_dir, response_format: format, warmup: false)
  end

  def rpc(server, arguments)
    params = { 'name' => 'path', 'arguments' => arguments }
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: params))
    JSON.parse(raw).fetch('result')
  end

  def text(result)
    result.dig('content', 0, 'text')
  end

  it 'is registered whatever is wired, and says what it does not cover' do
    tool = build.tools.fetch('path')

    expect(tool.description).to include('how does X reach Y').and include('not exhaustive source-reference coverage')
    expect(tool.input_schema_value.to_h[:required]).to eq(%w[from to])
  end

  describe 'a path that exists' do
    it 'lists one hop per line in markdown, with every via on an edge' do
      result = rpc(build, 'from' => 'OrdersController', 'to' => 'Post')

      expect(result['isError']).to be(false)
      expect(text(result)).to eq(<<~TEXT.chomp)
        ## Path from OrdersController to Post

        3 hops, forward: OrdersController (controller) reaches Post (model).

        1. OrdersController (controller) -[code_reference]-> CheckoutService (service)
        2. CheckoutService (service) -[code_reference, job_enqueue]-> PaymentGateway (service)
        3. PaymentGateway (service) -[code_reference]-> Post (model)

        #{coverage_notice}
      TEXT
    end

    it 'carries the same answer as structured data' do
      data = rpc(build, 'from' => 'OrdersController', 'to' => 'Post').dig('structuredContent', 'data')

      expect(data).to include('found' => true, 'direction' => 'forward', 'hop_count' => 3,
                              'from' => { 'identifier' => 'OrdersController', 'type' => 'controller' },
                              'to' => { 'identifier' => 'Post', 'type' => 'model' })
      expect(data['hops'][1]).to eq('source' => 'CheckoutService', 'source_type' => 'service',
                                    'target' => 'PaymentGateway', 'target_type' => 'service',
                                    'via' => %w[code_reference job_enqueue])
      expect(data['graph_coverage']).to include('scope' => 'published_relationships')
      expect(data).not_to have_key('hint')
    end

    it 'answers JSON in the json format' do
      result = rpc(build(:json), 'from' => 'Comment', 'to' => 'Post')
      parsed = JSON.parse(text(result))

      expect(parsed).to include('found' => true, 'hop_count' => 1)
      expect(parsed['hops']).to eq([{ 'source' => 'Comment', 'source_type' => 'model', 'target' => 'Post',
                                      'target_type' => 'model', 'via' => ['belongs_to'] }])
      expect(parsed).to eq(result.dig('structuredContent', 'data'))
    end

    it 'renders the plain and claude formats' do
      plain = text(rpc(build(:plain), 'from' => 'Comment', 'to' => 'Post'))
      claude = text(rpc(build(:claude), 'from' => 'Comment', 'to' => 'Post'))

      expect(plain).to start_with("Path from Comment to Post\n")
      expect(plain).to include('  1. Comment (model) -[belongs_to]-> Post (model)')
      expect(plain).not_to include('##')
      expect(claude).to start_with('<path from="Comment" to="Post">').and end_with('</path>')
      expect(claude).to include('1. Comment (model) -[belongs_to]-> Post (model)')
    end

    it 'answers the same unit as zero hops, not an error' do
      result = rpc(build, 'from' => 'Post', 'to' => 'Post')

      expect(result['isError']).to be(false)
      expect(text(result)).to include('0 hops: `from` and `to` are the same unit, Post (model).')
      expect(result.dig('structuredContent', 'data')).to include('found' => true, 'hop_count' => 0, 'hops' => [])
    end

    it 'finds the reverse path with direction either and says which way it runs' do
      result = rpc(build, 'from' => 'Post', 'to' => 'Comment', 'direction' => 'either')

      expect(result['isError']).to be(false)
      expect(text(result)).to include('1 hop, reverse: Comment (model) reaches Post (model). ' \
                                      'No published path leads forward from Post.')
      expect(text(result)).to include('1. Comment (model) -[belongs_to]-> Post (model)')
      expect(result.dig('structuredContent', 'data')).to include('direction' => 'reverse')
    end
  end

  describe 'no path' do
    it 'is a successful answer that says the search was exhaustive and suggests either' do
      result = rpc(build, 'from' => 'Post', 'to' => 'Comment')

      expect(result['isError']).to be(false)
      expect(result).not_to have_key('_meta')
      expect(text(result)).to include('No path: no chain of published edges leads from Post (model) to ' \
                                      'Comment (model). The search was exhaustive.')
      expect(text(result)).to include('Pass direction: "either" to also search from Comment toward Post.')
      expect(text(result)).to include(coverage_notice)
      expect(result.dig('structuredContent', 'data')).to include('found' => false, 'exhaustive' => true, 'hops' => [])
    end

    it 'says so when max_depth stopped the search, and never calls that no path' do
      result = rpc(build, 'from' => 'OrdersController', 'to' => 'Post', 'max_depth' => 2)
      data = result.dig('structuredContent', 'data')

      expect(result['isError']).to be(false)
      expect(text(result)).to include('No path within 2 hops from OrdersController (controller) to Post (model). ' \
                                      'The search stopped at max_depth, so this does not show that no path exists.')
      expect(text(result)).to include('Retry with a larger max_depth (maximum 20).')
      expect(text(result)).not_to include('The search was exhaustive')
      expect(data).to include('found' => false, 'exhaustive' => false, 'partial_reason' => 'max_depth')
    end

    it 'says so when the node budget stopped the search' do
      result = rpc(build, 'from' => 'OrdersController', 'to' => 'Post', 'max_nodes' => 2)

      expect(result['isError']).to be(false)
      expect(text(result)).to include('before the search reached its node budget (max_nodes 2). ' \
                                      'This does not show that no path exists.')
      expect(text(result)).to include('Retry with a larger max_nodes (maximum 10000).')
      expect(result.dig('structuredContent', 'data')).to include('exhaustive' => false,
                                                                 'partial_reason' => 'node_budget')
    end

    it 'does not route through a document, though one may be an endpoint' do
      through = rpc(build, 'from' => 'OrdersController', 'to' => 'Comment')
      ending = rpc(build, 'from' => 'OrdersController', 'to' => 'docs/checkout.md')

      expect(through.dig('structuredContent', 'data')).to include('found' => false, 'exhaustive' => true)
      expect(ending.dig('structuredContent', 'data')).to include('found' => true, 'hop_count' => 1)
    end

    context 'when max_depth stops one hop short of a document that is the goal' do
      let(:graph) do
        Woods::DependencyGraph.new.tap do |graph|
          [unit(:service, 'CheckoutService', 'PaymentGateway'), unit(:service, 'PaymentGateway', 'docs/payments.md'),
           unit(:doc, 'docs/payments.md')].each { |unit| graph.register(unit) }
        end
      end

      it 'says the bound stopped the search, not that no path exists' do
        result = rpc(build, 'from' => 'CheckoutService', 'to' => 'docs/payments.md', 'max_depth' => 1)

        expect(result.dig('structuredContent', 'data'))
          .to include('found' => false, 'exhaustive' => false, 'partial_reason' => 'max_depth')
        expect(text(result)).to include('The search stopped at max_depth, so this does not show that no path exists.')
        expect(text(result)).not_to include('The search was exhaustive')
      end
    end

    it 'does not suggest either once both directions were searched' do
      result = rpc(build, 'from' => 'Post', 'to' => 'OrdersController', 'direction' => 'forward')
      both = rpc(build, 'from' => 'reports', 'from_type' => 'factory', 'to' => 'OrdersController',
                        'direction' => 'either')

      expect(text(result)).to include('direction: "either"')
      expect(text(both)).to include('between reports (factory) and OrdersController (controller) in either direction')
      expect(text(both)).not_to include('direction: "either"')
    end
  end

  describe 'refusals' do
    %w[from to].each do |argument|
      it "answers not_found with near matches for an unknown #{argument}" do
        arguments = { 'from' => 'Post', 'to' => 'Post' }.merge(argument => 'post')
        result = rpc(build, arguments)

        expect(result['isError']).to be(true)
        expect(result['_meta']).to include('error_code' => 'not_found', 'tool' => 'path', 'argument' => argument,
                                           'identifier' => 'post',
                                           'suggestions' => [{ 'identifier' => 'Post', 'type' => 'model' }])
        expect(text(result)).to include("`#{argument}` unit not found: post.")
        expect(text(result)).to include('Did you mean: Post (model)?')
      end
    end

    it 'refuses an identifier registered under several types and names the argument to pass' do
      result = rpc(build, 'from' => 'reports', 'to' => 'Post')

      expect(result['isError']).to be(true)
      expect(result['_meta']).to include('error_code' => 'ambiguous_identity', 'tool' => 'path',
                                         'argument' => 'from_type', 'identifier' => 'reports',
                                         'types' => %w[database_view factory])
      expect(text(result)).to eq('`from` is ambiguous: reports is registered under 2 unit types ' \
                                 '(database_view, factory). Pass from_type with one of them.')
    end

    it 'refuses the same of `to`' do
      result = rpc(build, 'from' => 'Post', 'to' => 'reports')

      expect(result['_meta']).to include('error_code' => 'ambiguous_identity', 'argument' => 'to_type')
    end

    it 'resolves the identifier by the type named' do
      view = rpc(build, 'from' => 'reports', 'from_type' => 'database_view', 'to' => 'Post')
      factory = rpc(build, 'from' => 'reports', 'from_type' => 'factory', 'to' => 'Post')

      expect(text(view)).to include('1. reports (database_view) -[code_reference]-> Post (model)')
      expect(text(factory)).to include('2 hops, forward: reports (factory) reaches Post (model).')
    end

    it 'answers not_found for a type the identifier is not registered under' do
      result = rpc(build, 'from' => 'reports', 'from_type' => 'model', 'to' => 'Post')

      expect(result['isError']).to be(true)
      expect(result['_meta']).to include('error_code' => 'not_found', 'argument' => 'from')
      expect(text(result)).to include('`from` unit not found: reports (type model). ' \
                                      'It is registered as: database_view, factory.')
    end

    it 'takes one named type for both ends of the same identifier' do
      result = rpc(build, 'from' => 'reports', 'to' => 'reports', 'to_type' => 'factory')

      expect(result['isError']).to be(false)
      expect(text(result)).to include('0 hops: `from` and `to` are the same unit, reports (factory).')
    end
  end

  describe 'argument bounds' do
    it 'bounds max_depth and max_nodes at the wire contract' do
      properties = build.tools.fetch('path').input_schema_value.to_h[:properties]

      expect(properties[:max_depth]).to include(minimum: 1, maximum: 20)
      expect(properties[:max_nodes]).to include(minimum: 1, maximum: 10_000)
      expect(Woods::MCP::ToolContract::INTEGER_BOUNDS).to include('max_depth' => [1, 20])
    end

    [0, 21].each do |value|
      it "refuses max_depth #{value}" do
        result = rpc(build, 'from' => 'Comment', 'to' => 'Post', 'max_depth' => value)

        expect(result['isError']).to be(true)
        expect(result['_meta']).to include('error_code' => 'invalid_arguments', 'tool' => 'path')
      end
    end

    it 'accepts the bounds themselves' do
      [1, 20].each do |value|
        result = rpc(build, 'from' => 'Comment', 'to' => 'Post', 'max_depth' => value)

        expect(result['isError']).to be(false)
      end
    end

    it 'refuses a direction outside the enum and a missing endpoint' do
      sideways = rpc(build, 'from' => 'Comment', 'to' => 'Post', 'direction' => 'reverse')
      missing = rpc(build, 'from' => 'Comment')

      expect(sideways['_meta']).to include('error_code' => 'invalid_arguments')
      expect(missing['_meta']).to include('error_code' => 'missing_required_arguments', 'arguments' => ['to'])
    end
  end
end
