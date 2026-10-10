# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extractors/lexical_constant'

RSpec.describe Woods::Extractors::LexicalConstant do
  before do
    stub_const('Depot', Module.new)
    stub_const('Depot::Loader', Class.new)
    stub_const('Depot::Loader::PingJob', Class.new)
    stub_const('PingJob', Class.new)
    stub_const('Depot::LIMIT', 5)
  end

  it 'names a nested job the way the call site resolves it' do
    expect(described_class.resolve('PingJob', ['Depot::Loader', 'Depot'])).to eq('Depot::Loader::PingJob')
    expect(described_class.resolve('PingJob', ['Depot'])).to eq('PingJob')
  end

  it 'returns the reference as written when nothing loaded answers to it, or it is not a class or module' do
    expect(described_class.resolve('Missing::SyncJob', ['Depot'])).to eq('Missing::SyncJob')
    expect(described_class.resolve('LIMIT', ['Depot'])).to eq('LIMIT')
    expect(described_class.resolve('::PingJob', ['Depot::Loader'])).to eq('::PingJob')
  end

  it 'answers exactly as ConstantPaths.resolve does' do
    [['PingJob', ['Depot::Loader', 'Depot']], ['Loader::PingJob', ['Depot']], ['Depot::Loader', ['Unloaded']]]
      .each do |reference, nesting|
        expect(described_class.resolve(reference, nesting))
          .to eq(Woods::Extractors::ConstantPaths.resolve(reference, nesting).target)
      end
  end

  it 'names a pending autoload by its registration without triggering it' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'lazy_sync_job.rb')
      File.write(path, "module Depot; class LazySyncJob; end; end\n")
      Depot.autoload(:LazySyncJob, path)

      expect(described_class.resolve('LazySyncJob', ['Depot'])).to eq('Depot::LazySyncJob')
      expect(Depot.autoload?(:LazySyncJob)).to eq(path)
    end
  end
end
