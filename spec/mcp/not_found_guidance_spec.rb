# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/mcp/server'

# An identifier the index lacks must read as "not found", never as an empty
# answer, and should name the unit the caller most likely meant: an agent that
# reads an empty dependents list as "nothing depends on this" changes code it
# should not.
RSpec.describe 'MCP answers for an identifier the index lacks' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  def build(format, index_dir = fixture_dir)
    Woods::MCP::Server.build(index_dir: index_dir, response_format: format, warmup: false)
  end

  def call(server, tool, **arguments)
    server.instance_variable_get(:@tools).fetch(tool).call(**arguments, server_context: {})
  end

  def text(response)
    response.content.first[:text]
  end

  %i[markdown plain claude].each do |format|
    context "with the #{format} renderer" do
      let(:server) { build(format) }

      %w[dependents dependencies].each do |tool|
        it "says #{tool} traversed nothing, and suggests the unit meant" do
          answer = text(call(server, tool, identifier: 'post'))

          expect(answer).to include("Identifier 'post' not found in the index, so no #{tool} were traversed.")
          expect(answer).to include('Did you mean: Post (model)?')
        end
      end
    end
  end

  context 'with structured data' do
    let(:server) { build(:json) }

    it 'keeps found: false and adds the suggestions to a traversal' do
      data = JSON.parse(text(call(server, 'dependents', identifier: 'app/models/post.rb')))

      expect(data).to include('found' => false, 'nodes' => {},
                              'suggestions' => [{ 'identifier' => 'Post', 'type' => 'model' }])
    end

    it 'leaves suggestions empty when nothing is close' do
      data = JSON.parse(text(call(server, 'dependencies', identifier: 'Zeppelin')))

      expect(data).to include('found' => false, 'suggestions' => [])
      expect(data.fetch('message')).not_to include('Did you mean')
    end
  end

  describe 'lookup' do
    let(:server) { build(:markdown) }

    it 'suggests the owner of a Class#method reference' do
      response = call(server, 'lookup', identifier: 'Post#publish')

      expect(response.error?).to be(true)
      expect(text(response)).to eq('Unit not found: Post#publish. Did you mean: Post (model)?')
      expect(response.meta).to include(error_code: :not_found, suggestions: [{ identifier: 'Post', type: 'model' }])
    end

    it 'names the type an identifier is published under when another type was asked for' do
      response = call(server, 'lookup', identifier: 'Post', type: 'service')

      expect(text(response)).to eq('Unit not found: Post (type service). Did you mean: Post (model)?')
    end

    it 'adds nothing when no identifier is close' do
      response = call(server, 'lookup', identifier: 'Zeppelin')

      expect(text(response)).to eq('Unit not found: Zeppelin')
      expect(response.meta).to include(suggestions: [])
    end
  end

  it 'suggests an entry point for trace_flow' do
    response = call(build(:markdown), 'trace_flow', entry_point: 'post')

    expect(response.error?).to be(true)
    expect(text(response)).to include('Flow entry unit not found').and include('Did you mean: Post (model)?')
  end

  it 'suggests a unit for diagram' do
    response = call(build(:markdown), 'diagram', kind: 'neighbourhood', identifier: 'Pots')

    expect(response.error?).to be(true)
    expect(text(response)).to include('No unit Pots in this generation').and include('Did you mean: Post (model)?')
  end

  describe 'recent_changes without Git facts' do
    around do |example|
      Dir.mktmpdir('woods-mcp-git-notice') do |dir|
        FileUtils.cp_r(File.join(fixture_dir, '.'), dir)
        @index_dir = dir
        example.run
      end
    end

    def publish_git_enrichment(summary)
      path = File.join(@index_dir, 'manifest.json')
      manifest = JSON.parse(File.read(path, encoding: 'UTF-8'))
      File.write(path, JSON.generate(manifest.merge('git_enrichment' => summary)))
    end

    it 'says why the list is short when history could not be read' do
      publish_git_enrichment('version' => 1, 'state' => 'unavailable', 'reason' => 'shallow_repository')

      answer = text(call(build(:markdown, @index_dir), 'recent_changes'))

      expect(answer).to include('Git facts are unavailable for this index (shallow_repository)')
      expect(answer).to include('does not mean nothing changed')
    end

    it 'adds no notice when Git facts are available' do
      publish_git_enrichment('version' => 1, 'state' => 'available', 'reason' => nil)

      expect(text(call(build(:markdown, @index_dir), 'recent_changes'))).not_to include('Git facts are')
    end

    it 'adds no notice to an index that predates the summary' do
      expect(text(call(build(:markdown), 'recent_changes'))).not_to include('Git facts are')
    end
  end
end
