# frozen_string_literal: true

require 'spec_helper'
require 'woods/flow_precomputer'
require 'woods/extracted_unit'

RSpec.describe 'Flow identity' do
  it 'keeps namespaced and double-underscore controllers separately readable' do
    Dir.mktmpdir do |dir|
      graph = Woods::DependencyGraph.new
      units = ['Admin::UsersController', 'Admin__UsersController'].map do |id|
        unit = Woods::ExtractedUnit.new(type: :controller, identifier: id, file_path: 'app/controllers/example.rb')
        unit.metadata = { actions: ['index'] }
        unit.source_code = "class #{id}; def index; end; end"
        FileUtils.mkdir_p(File.join(dir, 'controllers'))
        name = Object.new.extend(Woods::FilenameUtils).collision_safe_filename(id)
        File.write(File.join(dir, 'controllers', name), JSON.generate(unit.to_h))
        graph.register(unit)
        unit
      end
      paths = Woods::FlowPrecomputer.new(units: units, graph: graph, output_dir: dir).precompute
      expect(paths.values.uniq.size).to eq(2)
      paths.each { |id, path| expect(JSON.parse(File.read(File.join(dir, path)))['entry_point']).to eq(id) }
    end
  end
end
