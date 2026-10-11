# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/tasks'

RSpec.describe 'code_reference edges by caller type in woods:stats (#655)' do
  def reference(target, type)
    { 'type' => type, 'target' => target, 'via' => 'code_reference' }
  end

  let(:graph) do
    {
      'nodes' => { 'Shipment' => { 'type' => 'model' }, 'ShipmentQuote' => { 'type' => 'service' },
                   'Ui::Card' => { 'type' => 'component' }, 'Ledger' => { 'type' => 'poro' } },
      'edges' => {
        'Shipment' => [{ 'type' => 'model', 'target' => 'Ledger', 'via' => 'belongs_to' }],
        'ShipmentQuote' => [reference('Shipment', 'model')],
        'Ui::Card' => [reference('Shipment', 'model'), reference('ShipmentQuote', 'service'),
                       { 'type' => 'component', 'target' => 'Ui::Badge', 'via' => 'render' }],
        'Ledger' => []
      },
      'variants' => [{ 'identifier' => 'Ledger', 'type' => 'job', 'edges' => [reference('Shipment', 'model')] }],
      'reverse' => {}, 'file_map' => {}, 'type_index' => {}, 'stats' => { 'node_count' => 5, 'edge_count' => 6 }
    }
  end

  describe 'Woods::Tasks.code_reference_counts' do
    it 'counts code_reference edges by caller type, variants included, sorted by type' do
      Dir.mktmpdir('woods-stats') do |index|
        File.write(File.join(index, 'dependency_graph.json'), JSON.generate(graph))
        expect(Woods::Tasks.code_reference_counts(index))
          .to eq('component' => 2, 'job' => 1, 'service' => 1)
      end
    end

    it 'is empty for an index without a graph' do
      Dir.mktmpdir('woods-stats') { |index| expect(Woods::Tasks.code_reference_counts(index)).to eq({}) }
    end
  end

  it 'prints the counts under the dependency graph section of woods:stats' do
    Dir.mktmpdir('woods-stats-task') do |index|
      root = File.expand_path('../..', __dir__)
      File.write(File.join(index, 'manifest.json'), JSON.generate(counts: {}))
      File.write(File.join(index, 'dependency_graph.json'), JSON.generate(graph))
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
                                             File.join(root, 'bin/rake'), 'woods:stats', chdir: index)

      expect(status.exitstatus).to eq(0), "#{output}\n#{error}"
      expect(output).to include('Edges: 6', 'code_reference edges by caller type', 'component', 'job', 'service')
      expect(output.lines.map(&:rstrip)).to include('    component      :    2', '    job            :    1',
                                                    '    service        :    1', '    Total          :    4')
    end
  end
end
