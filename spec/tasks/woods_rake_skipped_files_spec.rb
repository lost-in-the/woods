# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/rake_helpers'

RSpec.describe 'skipped-files summary in woods:extract and woods:validate (#672)' do
  let(:report) do
    { 'total' => 3, 'counts' => { 'namespace_only' => 2, 'rejected_by:services' => 1 },
      'files' => [{ 'path' => 'app/models/billing.rb', 'reason' => 'namespace_only' }] }
  end

  describe 'Woods::RakeHelpers.woods_skipped_files_summary' do
    it 'summarises the published report by reason' do
      Dir.mktmpdir('woods-skipped') do |index|
        File.write(File.join(index, 'skipped_files.json'), JSON.generate(report))

        expect(Woods::RakeHelpers.woods_skipped_files_summary(index))
          .to eq('Skipped files: 3 (namespace_only: 2, rejected_by:services: 1); see skipped_files.json')
      end
    end

    it 'says nothing for an index published before the report existed' do
      Dir.mktmpdir('woods-skipped') do |index|
        expect(Woods::RakeHelpers.woods_skipped_files_summary(index)).to be_nil
      end
    end
  end

  it 'prints the summary as information without failing woods:validate' do
    Dir.mktmpdir('woods-validate-skipped') do |index|
      root = File.expand_path('../..', __dir__)
      FileUtils.mkdir_p(File.join(index, 'models'))
      File.write(File.join(index, 'manifest.json'), JSON.generate(counts: { models: 1 }))
      File.write(File.join(index, 'models', '_index.json'), JSON.generate([{ identifier: 'A' }]))
      File.write(File.join(index, 'models', 'A.json'),
                 JSON.generate(identifier: 'A', type: 'model', source_code: 'class A; end'))
      File.write(File.join(index, 'dependency_graph.json'),
                 JSON.generate(nodes: { A: { type: 'model', file_path: nil } }, edges: { A: [] }, reverse: {},
                               file_map: {}, type_index: { model: ['A'] }))
      File.write(File.join(index, 'skipped_files.json'), JSON.generate(report))
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

      expect(status.exitstatus).to eq(0), "#{output}\n#{error}"
      expect(output).to include('INFO:', 'Skipped files: 3 (namespace_only: 2, rejected_by:services: 1)')
    end
  end
end
