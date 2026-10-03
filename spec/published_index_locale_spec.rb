# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# PublishedIndex is what woods:check:* tasks, RuboCop cops and gate scripts
# read the index through, in a plain Ruby process with no Rails boot. Nothing
# there sets Encoding.default_external, so under LC_ALL=C it is US-ASCII and
# every artifact read must still come back as valid UTF-8.
RSpec.describe 'Woods::PublishedIndex in a process under a POSIX locale' do
  let(:fixture_dir) { File.expand_path('fixtures/woods', __dir__) }
  let(:lib_dir) { File.expand_path('../lib', __dir__) }

  let(:reader_script) do
    <<~RUBY
      require 'json'
      require 'woods/published_index'

      index = Woods::PublishedIndex.new(ARGV.fetch(0))
      post = index.unit('Post')
      report = {
        default_external: Encoding.default_external.name,
        source: post['source_code'],
        source_valid: post['source_code'].valid_encoding?,
        models: index.units(type: 'model').map { |entry| entry['identifier'] },
        summaries: index.units(type: 'model').filter_map { |entry| entry['summary'] },
        branch: index.manifest['git_branch'],
        dependents: index.dependents_of('Post')
      }
      index.close
      $stdout.binmode
      $stdout.write(JSON.generate(report))
    RUBY
  end

  def multibyte_index(dir)
    FileUtils.cp_r(Dir[File.join(fixture_dir, '*')], dir)
    rewrite_json(File.join(dir, 'models', 'Post_a5554622.json')) do |post|
      post.merge('source_code' => "# Post — café entries\n#{post['source_code']}")
    end
    rewrite_json(File.join(dir, 'models', '_index.json')) do |entries|
      entries.map { |entry| entry['identifier'] == 'Post' ? entry.merge('summary' => 'Post — café entries') : entry }
    end
    rewrite_json(File.join(dir, 'manifest.json')) { |manifest| manifest.merge('git_branch' => 'feature/café') }
    rewrite_json(File.join(dir, 'dependency_graph.json')) do |graph|
      graph['nodes']['Post']['summary'] = 'Post — café entries'
      graph
    end
  end

  def rewrite_json(path)
    data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
    File.binwrite(path, JSON.generate(yield(data)))
  end

  it 'reads multibyte units, entries and the graph as UTF-8 with no Rails boot' do
    Dir.mktmpdir('woods-locale-index') do |dir|
      multibyte_index(dir)

      stdout, stderr, status = Open3.capture3({ 'LC_ALL' => 'C', 'LANG' => 'C', 'RUBYOPT' => nil },
                                              RbConfig.ruby, '-rbundler/setup', '-I', lib_dir,
                                              '-e', reader_script, dir)

      expect(status).to be_success, stderr
      report = JSON.parse(stdout.force_encoding(Encoding::UTF_8))
      expect(report).to include('default_external' => 'US-ASCII', 'source_valid' => true)
      expect(report['source']).to start_with("# Post — café entries\n")
      expect(report['models']).to include('Post', 'Comment')
      expect(report['dependents']).to include('Comment')
      expect(report['summaries']).to eq(['Post — café entries'])
      expect(report['branch']).to eq('feature/café')
    end
  end
end
