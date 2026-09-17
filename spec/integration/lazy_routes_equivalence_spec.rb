# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/generation'

RSpec.describe 'Fresh-process lazy route extraction', :booted_app do
  it 'preserves navigation, reverse edges and graph analysis after a changed view' do
    Dir.mktmpdir('woods_lazy_routes') do |root|
      app = File.join(root, 'app')
      FileUtils.cp_r(File.expand_path('../dummy', __dir__), app)
      view = File.join(app, 'app/views/posts/index.html.erb')
      FileUtils.mkdir_p(File.dirname(view))
      File.write(view, '<%= link_to "Posts", posts_path %>')
      incremental = File.join(root, 'incremental')
      full = File.join(root, 'full')
      extract(app, incremental, 'probe')
      extract(app, incremental, 'full')
      File.write(view, '<h1>Updated</h1><%= link_to "Posts", posts_path %>')
      extract(app, incremental, 'incremental')
      extract(app, full, 'full')

      inc_graph = artifact(incremental, 'dependency_graph.json')
      full_graph = artifact(full, 'dependency_graph.json')
      expect(inc_graph).to eq(full_graph)
      expect(inc_graph.fetch('reverse').fetch('PostsController')).to include('posts/index.html.erb')
      expect(artifact(incremental, 'graph_analysis.json').except('generated_at')).to eq(
        artifact(full, 'graph_analysis.json').except('generated_at')
      )
    end
  end

  def extract(app, output, mode)
    script = File.expand_path('../fixtures/lazy_routes_extraction.rb', __dir__)
    stdout, stderr, status = Open3.capture3(
      { 'RAILS_ENV' => 'test' }, Gem.ruby, '-I', File.expand_path('../../lib', __dir__),
      script, app, output, mode
    )
    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end

  def artifact(index, name)
    JSON.parse(File.read(File.join(Woods::Generation.new(output_dir: index).payload_dir, name)))
  end
end
