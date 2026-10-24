# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'stringio'
require 'woods'
require 'woods/diagrams/task'

RSpec.describe 'woods:diagram' do
  include DiagramIndex

  let(:environment_keys) { %w[WOODS_OUTPUT TYPE DEPTH DIRECTION EVENT TYPES VIA] }

  around do |example|
    previous_rake = Rake.application
    previous_env = environment_keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    previous_out = $stdout
    previous_err = $stderr
    environment_keys.each { |key| ENV.delete(key) }
    ENV['WOODS_OUTPUT'] = diagram_root
    @out = $stdout = StringIO.new
    @err = $stderr = StringIO.new
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment) { raise 'must not boot Rails' }
    load File.expand_path('../../lib/tasks/woods.rake', __dir__)
    Woods::Diagrams::Cache.clear
    example.run
  ensure
    Rake.application = previous_rake
    previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    $stdout = previous_out
    $stderr = previous_err
  end

  def invoke(*args)
    Rake::Task['woods:diagram'].invoke(*args)
  end

  it 'prints the Mermaid of one unit without booting Rails' do
    invoke('schema', 'Post')
    expect(@out.string).to eq(<<~MERMAID)
      erDiagram
        "posts"
        "posts" }o--|| "users" : "author"
        "posts" ||--o{ "comments" : "comments"
    MERMAID
  end

  it 'takes the tool\'s arguments from the environment' do
    ENV['DEPTH'] = '2'
    ENV['EVENT'] = 'create'
    invoke('lifecycle', 'Post')
    expect(@out.string).to include('A0-)A1: weekly (deliver_later)', 'A2->>A2: User.find.touch')
    Rake::Task['woods:diagram'].reenable
    @out.truncate(0)
    @out.rewind
    ENV['DEPTH'] = '1'
    ENV['VIA'] = 'belongs_to, has_many'
    invoke('neighbourhood', 'Post')
    expect(@out.string.scan('-->').size).to eq(4)
  end

  it 'gives each kind only its own options, so one left in the shell does no harm' do
    ENV['EVENT'] = 'update'
    ENV['DIRECTION'] = 'dependents'
    invoke('schema', 'Comment')
    expect(@out.string).to start_with("erDiagram\n")
  end

  it 'fails with the refusal on standard error when the diagram is over its budget' do
    stub_const('Woods::Diagrams::Schema::TABLE_BUDGET', 2)
    expect { invoke('schema', 'Post') }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(@out.string).to be_empty
    expect(@err.string).to eq("3 tables is over the ER budget of 2 (depth 1); lower DEPTH or narrow TYPES/VIA.\n")
  end

  it 'aborts with the reason for a bad request or an unknown unit' do
    ENV['DEPTH'] = '9'
    expect { invoke('schema', 'Post') }.to raise_error(SystemExit)
    expect(@err.string).to include('schema depth must be 1 to 3')
    Rake::Task['woods:diagram'].reenable
    ENV.delete('DEPTH')
    expect { invoke('schema', 'Nope') }.to raise_error(SystemExit)
    expect(@err.string).to include('No unit Nope in this generation')
  end
end
