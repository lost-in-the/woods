# frozen_string_literal: true

require 'spec_helper'
require 'active_support/all'
require 'woods'
require 'woods/extractor'
require 'tmpdir'
require 'open3'

RSpec.describe Woods::Extractor, 'HEAD git enrichment' do
  let(:root) { Pathname.new(Dir.mktmpdir('woods_git_history')) }
  let(:extractor) { described_class.new(output_dir: root.join('output')) }
  let(:path) { root.join('sample.rb').to_s }

  def git(*args)
    output, status = Open3.capture2e('git', '-C', root.to_s, *args)
    raise output unless status.success?

    output.strip
  end

  def commit(message, author: 'Main Author')
    File.write(path, "#{message}\n")
    git('add', 'sample.rb')
    git('commit', '-qm', message, "--author=#{author} <test@example.invalid>")
  end

  def metadata
    extractor.send(:batch_git_data, [path]).fetch('sample.rb')
  end

  before do
    stub_const('Rails', double('Rails', root: root, logger: double('Logger').as_null_object))
    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Main Author')
    git('config', 'user.email', 'test@example.invalid')
    commit('main commit')
    git('checkout', '-qb', 'unmerged')
    commit('checkpoint commit', author: 'Checkpoint Author')
    git('update-ref', 'refs/t3/checkpoints/test', 'HEAD')
    git('update-ref', 'refs/remotes/origin/unmerged', 'HEAD')
    git('checkout', '-q', 'main')
  end

  after { FileUtils.rm_rf(root) }

  it 'excludes unmerged branches, remote refs and checkpoint refs' do
    expect(metadata).to include(commit_count: 1, last_author: 'Main Author', change_frequency: :new)
    expect(metadata[:contributors]).to eq([{ name: 'Main Author', commits: 1 }])
    expect(metadata[:recent_commits].map { |entry| entry[:message] }).to eq(['main commit'])
  end

  it 'uses the same HEAD history for full and incremental enrichment' do
    unit = Woods::ExtractedUnit.new(type: :service, identifier: 'Sample', file_path: path)
    extractor.instance_variable_set(:@results, { services: [unit] })
    extractor.dependency_graph.register(unit)

    extractor.send(:enrich_with_git_data)
    incremental = extractor.send(:incremental_git_data, ['Sample'])

    expect(unit.metadata[:git][:commit_count]).to eq(1)
    expect(incremental.fetch('sample.rb')).to eq(unit.metadata[:git])
  end

  it 'applies the full path exclusions to incremental git enrichment across typed collisions' do
    external = root.parent.join("#{root.basename}-external.rb")
    paths = [root.join('vendor/bundle/gem.rb'), root.join('node_modules/package.js'), external]
    paths.each do |excluded|
      FileUtils.mkdir_p(excluded.dirname)
      File.write(excluded, 'excluded')
    end
    units = [Woods::ExtractedUnit.new(type: :service, identifier: 'Sample', file_path: path)]
    paths.zip(%i[model component controller]).each do |excluded, type|
      units << Woods::ExtractedUnit.new(type: type, identifier: 'Sample', file_path: excluded.to_s)
    end
    units << Woods::ExtractedUnit.new(type: :job, identifier: 'Missing', file_path: root.join('missing.rb').to_s)
    units << Woods::ExtractedUnit.new(type: :mailer, identifier: 'NoPath', file_path: nil)
    units << Woods::ExtractedUnit.new(type: :gem_source, identifier: 'Gem', file_path: path)
    units << Woods::ExtractedUnit.new(type: :rails_source, identifier: 'Rails', file_path: path)
    results = units.group_by { |unit| described_class::TYPE_TO_EXTRACTOR_KEY.fetch(unit.type) }
    extractor.instance_variable_set(:@results, results)
    units.each { |unit| extractor.dependency_graph.register(unit) }

    extractor.send(:enrich_with_git_data)
    incremental = extractor.send(:incremental_git_data, units.map(&:identifier).uniq)

    expect(incremental.keys).to eq(['sample.rb'])
    expect(incremental.fetch('sample.rb')).to eq(units.first.metadata.fetch(:git))
    expect(units.drop(1).map { |unit| unit.metadata[:git] }).to all(be_nil)
    expect(extractor.send(:git_for_type, 'Sample', :service, incremental)).to eq(units.first.metadata[:git])
    %i[model component controller].each do |type|
      expect(extractor.send(:git_for_type, 'Sample', type, incremental)).to be_nil
    end
  ensure
    FileUtils.rm_f(external) if external
  end

  it 'includes side-branch changes after they are merged into HEAD' do
    git('merge', '--no-ff', '-qm', 'merge side', 'unmerged')

    expect(metadata[:recent_commits].map { |entry| entry[:message] }).to include('checkpoint commit')
  end

  it 'uses detached HEAD without following other refs' do
    git('checkout', '--detach', '-q', 'main')

    expect(metadata[:commit_count]).to eq(1)
  end

  it 'uses the linked worktree HEAD independently of the process cwd' do
    commit('main-only commit')
    worktree = root.join('linked')
    git('worktree', 'add', '-q', worktree.to_s, 'unmerged')
    allow(Rails).to receive(:root).and_return(worktree)

    data = extractor.send(:batch_git_data, [worktree.join('sample.rb').to_s])
    expect(data.fetch('sample.rb')[:commit_count]).to eq(2)
    messages = data.fetch('sample.rb')[:recent_commits].map { |entry| entry[:message] }
    expect(messages).to contain_exactly('main commit', 'checkpoint commit')
  end
end
