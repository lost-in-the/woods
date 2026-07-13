# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'woods'
require 'woods/explorer/screen_builder'

RSpec.describe Woods::Explorer::ScreenBuilder do
  # Sorted node order (DataBuilder convention):
  #   0 Admin::DashboardController, 1 ButtonComponent, 2 CommentsController,
  #   3 PostsController, 4 posts/index view
  let(:nodes) do
    [
      { 'id' => 'Admin::DashboardController', 'type' => 'controller',
        'facts' => { 'routes' => { 'home' => ['GET /'], 'index' => ['GET /admin/dashboard'] } } },
      { 'id' => 'ButtonComponent', 'type' => 'component', 'facts' => {} },
      { 'id' => 'CommentsController', 'type' => 'controller',
        'facts' => { 'routes' => { 'create' => ['POST /posts/:post_id/comments'] } } },
      { 'id' => 'PostsController', 'type' => 'controller',
        'facts' => { 'routes' => { 'create' => ['POST /posts'], 'index' => ['GET /posts'] } } },
      { 'id' => 'posts/index.html.erb', 'type' => 'view', 'facts' => {} }
    ]
  end

  # controller -> view -> component render chain, a link_to leaving the
  # component, a server redirect, and one non-navigation edge for filtering.
  let(:edges) do
    [
      [3, 4, 'render'],
      [4, 1, 'view_render'],
      [1, 2, 'link_to'],
      [3, 2, 'redirect_to'],
      [3, 2, 'code_reference']
    ]
  end

  let(:flow_digest) do
    { 'summaries' => [
        { 'entry' => 'PostsController#create', 'responses' => ['redirect:302'] },
        { 'entry' => 'PostsController#preview', 'responses' => [] },
        { 'entry' => 'MissingController#show', 'responses' => [] }
      ],
      'ops' => [], 'unit_index' => {}, 'method_index' => {} }
  end

  let(:labels) do
    { 'screens' => { 'PostsController#index' => 'Post feed' },
      'domains' => { '/admin' => 'Administration' } }
  end

  let(:screens) do
    described_class.new(nodes: nodes, edges: edges, flow_digest: flow_digest, labels: labels).build
  end

  def screen(id)
    screens.find { |s| s['id'] == id }
  end

  describe '#build discovery' do
    it 'derives one screen per routed controller action plus flow-only entries, sorted by id' do
      expect(screens.map { |s| s['id'] })
        .to eq(['Admin::DashboardController#home', 'Admin::DashboardController#index',
                'CommentsController#create', 'PostsController#create',
                'PostsController#index', 'PostsController#preview'])
    end

    it 'ignores flow entries whose controller is not a known node' do
      expect(screens.map { |s| s['controller'] }).not_to include('MissingController')
    end

    it 'preserves route display strings verbatim' do
      expect(screen('PostsController#create')['routes']).to eq(['POST /posts'])
      expect(screen('CommentsController#create')['routes']).to eq(['POST /posts/:post_id/comments'])
    end

    it 'gives a flow-only screen (no route) an empty routes list' do
      expect(screen('PostsController#preview')['routes']).to eq([])
    end

    it 'points each screen at its controller node index' do
      expect(screen('PostsController#index')['node']).to eq(3)
      expect(screen('Admin::DashboardController#home')['node']).to eq(0)
    end
  end

  describe '#build flow linkage' do
    it 'attaches the matching flow summary index' do
      expect(screen('PostsController#create')['flow']).to eq(0)
      expect(screen('PostsController#preview')['flow']).to eq(1)
    end

    it 'leaves flow nil for actions without a precomputed flow' do
      expect(screen('PostsController#index')['flow']).to be_nil
    end
  end

  describe '#build domains' do
    it 'derives the domain from the first path segment, humanized' do
      expect(screen('PostsController#index')['domain']).to eq('Posts')
      expect(screen('CommentsController#create')['domain']).to eq('Posts')
    end

    it 'prefers a labels override keyed by "/segment"' do
      expect(screen('Admin::DashboardController#index')['domain']).to eq('Administration')
    end

    it 'falls back to the controller namespace for a root path' do
      expect(screen('Admin::DashboardController#home')['domain']).to eq('Admin')
    end
  end

  describe '#build labels' do
    it 'uses the explicit screen label when present' do
      expect(screen('PostsController#index')['label']).to eq('Post feed')
    end

    it 'humanizes "Controller — Action" as the fallback' do
      expect(screen('PostsController#create')['label']).to eq('Posts — Create')
      expect(screen('Admin::DashboardController#home')['label']).to eq('Dashboard — Home')
    end
  end

  describe '#build navigation' do
    it 'collects link targets from the render closure, marked controller-precise with ~' do
      expect(screen('PostsController#index')['out']).to include('~CommentsController')
    end

    it 'records server redirect edges as redirect: entries' do
      expect(screen('PostsController#index')['out']).to include('redirect:CommentsController')
    end

    it 'keeps flow response statuses out of the navigation list (they name no target)' do
      # "redirect:302" is an outcome, not a destination — navigation targets
      # come from redirect_to edges, which carry the actual controller.
      expect(screen('PostsController#create')['out'])
        .not_to include(a_string_matching(/302/))
    end

    it 'does not treat non-navigation edges as outbound links' do
      expect(screen('PostsController#index')['out'])
        .to contain_exactly('~CommentsController', 'redirect:CommentsController')
    end

    it 'increments inbound counts on the targeted controller screens' do
      # Each of the three PostsController screens links (~) and redirects to
      # CommentsController: 3 screens * 2 entries = 6.
      expect(screen('CommentsController#create')['in']).to eq(6)
      expect(screen('PostsController#index')['in']).to eq(0)
    end
  end

  describe 'determinism' do
    it 'produces identical output across independent builds' do
      twin = described_class.new(nodes: nodes, edges: edges,
                                 flow_digest: flow_digest, labels: labels).build
      expect(screens).to eq(twin)
      expect(screens.map { |s| s['id'] }).to eq(screens.map { |s| s['id'] }.sort)
    end
  end

  describe '.load_labels' do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def write_labels(content)
      path = File.join(@dir, 'woods_labels.yml')
      File.write(path, content)
      path
    end

    it 'returns {} for a nil path' do
      expect(described_class.load_labels(nil)).to eq({})
    end

    it 'returns {} for a missing file' do
      expect(described_class.load_labels(File.join(@dir, 'nope.yml'))).to eq({})
    end

    it 'returns {} for unparseable YAML' do
      expect(described_class.load_labels(write_labels("{{{\n\t:::"))).to eq({})
    end

    it 'returns {} for YAML that is not a mapping' do
      expect(described_class.load_labels(write_labels("- just\n- a list\n"))).to eq({})
    end

    it 'parses a valid labels file' do
      path = write_labels({ 'screens' => { 'PostsController#index' => 'Post feed' },
                            'domains' => { '/admin' => 'Administration' } }.to_yaml)
      expect(described_class.load_labels(path))
        .to eq('screens' => { 'PostsController#index' => 'Post feed' },
               'domains' => { '/admin' => 'Administration' })
    end
  end
end
