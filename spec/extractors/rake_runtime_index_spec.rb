# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'woods/extractors/rake_runtime_index'

RSpec.describe Woods::Extractors::RakeRuntimeIndex do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def load_rake(source, record_metadata: false)
    path = File.join(@dir, 'ledger.rake')
    File.write(path, source)
    application = Rake::Application.new
    previous = Rake::TaskManager.record_task_metadata
    Rake::TaskManager.record_task_metadata = record_metadata
    Rake.with_application(application) { load path }
    [described_class.new(application), path]
  ensure
    Rake::TaskManager.record_task_metadata = previous
  end

  it 'is unavailable without an application or without tasks' do
    expect(described_class.new(nil)).not_to be_available
    expect(described_class.new(Rake::Application.new)).not_to be_available
    expect(described_class.new(nil).tasks_at('/nowhere.rake', 1, 1)).to eq([])
  end

  it 'finds the tasks whose action starts inside a line range' do
    index, path = load_rake(<<~RAKE)
      namespace :ledger do
        %w[open close].each do |step|
          task "\#{step}_books", [:year] => :environment do
          end
        end
        task :audit do
        end
      end
      task :environment
    RAKE

    expect(index).to be_available
    expect(index.tasks_at(path, 3, 3)).to eq(
      [
        { name: 'ledger:close_books', prerequisites: %w[environment], arguments: %w[year],
          description: nil, kind: :task },
        { name: 'ledger:open_books', prerequisites: %w[environment], arguments: %w[year],
          description: nil, kind: :task }
      ]
    )
    expect(index.tasks_at(path, 6, 6).map { |task| task[:name] }).to eq(['ledger:audit'])
    expect(index.tasks_at(path, 1, 2)).to eq([])
    expect(index.tasks_at(File.join(@dir, 'other.rake'), 3, 3)).to eq([])
  end

  it 'finds a blockless task and its description when Rake recorded task metadata' do
    index, path = load_rake(<<~RAKE, record_metadata: true)
      desc "Build \#{'every'} report"
      multitask reports: %i[daily weekly]
      task :daily
      task :weekly
    RAKE

    expect(index.tasks_at(path, 2, 2)).to eq(
      [{ name: 'reports', prerequisites: %w[daily weekly], arguments: [], description: 'Build every report',
         kind: :multitask }]
    )
  end

  it 'reads the process-wide application through .current' do
    expect(described_class.current).to be_a(described_class)
  end
end
