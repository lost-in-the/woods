# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'woods'

RSpec.describe 'woods:validate semantic graph errors (#413)' do
  it 'reports the missing reverse relationship and exits unsuccessfully without repairing it' do
    Dir.mktmpdir('woods-validate-graph') do |index|
      root = File.expand_path('../..', __dir__)
      FileUtils.mkdir_p(File.join(index, 'models'))
      File.write(File.join(index, 'manifest.json'), JSON.generate(counts: { models: 1 }))
      File.write(File.join(index, 'models', '_index.json'), JSON.generate([{ identifier: 'A' }]))
      File.write(File.join(index, 'models', 'A.json'),
                 JSON.generate(identifier: 'A', type: 'model', source_code: 'class A; end'))
      graph = { nodes: { A: { type: 'model', file_path: nil } }, edges: { A: ['http_api'] },
                reverse: {}, file_map: {}, type_index: { model: ['A'] } }
      graph_path = File.join(index, 'dependency_graph.json')
      File.write(graph_path, JSON.generate(graph))
      original = File.read(graph_path)
      File.write(File.join(index, 'Rakefile'), <<~RUBY)
        $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
        require 'rake'
        require 'pathname'
        require 'woods'
        module Rails
          def self.root
            Pathname.new(#{index.inspect})
          end
        end
        task :environment
        load #{File.join(root, 'lib/tasks/woods.rake').inspect}
      RUBY

      output, error, status = Open3.capture3({ 'WOODS_OUTPUT' => index }, RbConfig.ruby,
                                             File.join(root, 'bin/rake'), 'woods:validate', chdir: index)

      expect(status.exitstatus).to eq(1), "#{output}\n#{error}"
      expect(output).to include('reverse["http_api"]: missing "A"', 'Index has 1 error(s)')
      expect(File.read(graph_path)).to eq(original)
    end
  end
end
