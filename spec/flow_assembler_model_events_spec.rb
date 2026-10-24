# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/dependency_graph'
require 'woods/flow_assembler'

# W-5 (#755): a flow can start from a model callback event. `Post@create`
# runs the callbacks Rails runs for a create, in chain order;
# `Post@after_commit(create)` narrows to one callback type; `Post@after_commit`
# takes that type for every event.
RSpec.describe Woods::FlowAssembler, 'model callback event entries' do
  let(:graph) { instance_double(Woods::DependencyGraph) }
  let(:extracted_dir) { Dir.mktmpdir('flow_assembler_events') }

  after { FileUtils.remove_entry(extracted_dir) }

  def write_unit(identifier, source_code:, type:, metadata: {})
    dir = File.join(extracted_dir, "#{type}s")
    FileUtils.mkdir_p(dir)
    base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    digest = Digest::SHA256.hexdigest(identifier)[0, 8]
    data = { 'type' => type, 'identifier' => identifier, 'file_path' => "app/#{type}s/#{base.downcase}.rb",
             'source_code' => source_code, 'metadata' => metadata }
    File.write(File.join(dir, "#{base}_#{digest}.json"), JSON.generate(data))
  end

  def callback(type, filter, kind, conditions = {})
    { 'type' => type, 'filter' => filter, 'kind' => kind, 'conditions' => conditions }
  end

  let(:post_callbacks) do
    [
      callback('before_validation', 'normalize_title', 'before'),
      callback('before_save', 'set_slug', 'before', 'if' => [':title_changed?']),
      callback('before_save', 'autosave_associated_records_for_author', 'before'),
      callback('after_create', 'log_creation', 'after'),
      callback('after_update', 'log_update', 'after'),
      callback('after_commit', 'notify_subscribers', 'after', 'on' => ['create']),
      callback('after_commit', 'reindex', 'after', 'on' => %w[create update]),
      callback('after_commit', 'purge_cache', 'after', 'on' => ['destroy']),
      callback('before_destroy', 'check_locked', 'before')
    ]
  end

  before do
    write_unit('Post', type: 'model', metadata: { 'callbacks' => post_callbacks }, source_code: <<~RUBY)
      class Post < ApplicationRecord
        def normalize_title = self.title = title.strip
        def set_slug = self.slug = title.parameterize
        def log_creation = Rails.logger.info("created")
        def log_update = Rails.logger.info("updated")
        def notify_subscribers
          NotifySubscribersJob.perform_later(id)
        end
        def reindex = SearchIndex.update(self)
        def purge_cache = Rails.cache.delete(cache_key)
        def check_locked = throw(:abort) if locked?
      end
    RUBY
    write_unit('NotifySubscribersJob', type: 'job', source_code: <<~RUBY)
      class NotifySubscribersJob < ApplicationJob
        def perform(post_id)
          MailingListMailer.new_post(post_id).deliver_later
        end
      end
    RUBY
    allow(graph).to receive(:node_exists?) { |id| %w[Post NotifySubscribersJob].include?(id) }
    allow(graph).to receive_messages(find_node_by_suffix: nil, find_all_by_suffix: [])
  end

  let(:assembler) { described_class.new(graph: graph, extracted_dir: extracted_dir) }

  def callback_names(flow)
    flow.steps.first[:operations].map { |op| op[:method] }
  end

  it 'lists the callbacks a create runs, in chain order, scoped by their on: actions' do
    flow = assembler.assemble('Post@create')
    expect(flow.entry_point).to eq('Post@create')
    expect(flow.steps.first).to include(unit: 'Post@create', type: 'model_event')
    expect(callback_names(flow)).to eq(%w[normalize_title set_slug autosave_associated_records_for_author
                                          log_creation notify_subscribers reindex])
  end

  it 'labels each callback with its type and conditions, and marks framework callbacks unexpanded' do
    ops = assembler.assemble('Post@create').steps.first[:operations]
    expect(ops[1]).to include(type: :callback, callback: 'before_save', target: 'Post', method: 'set_slug',
                              conditions: { 'if' => [':title_changed?'] })
    expect(ops[2]).to include(method: 'autosave_associated_records_for_author', unexpanded: 'not defined in the unit')
  end

  it 'expands each application callback into its own step, following async hops' do
    units = assembler.assemble('Post@create').steps.map { |step| step[:unit] }
    expect(units).to eq(['Post@create', 'Post#normalize_title', 'Post#set_slug', 'Post#log_creation',
                         'Post#notify_subscribers', 'NotifySubscribersJob', 'Post#reindex'])
  end

  it 'follows a mailer delivery into the mailer action and names it on the operation' do
    write_unit('MailingListMailer', type: 'mailer', source_code: <<~RUBY)
      class MailingListMailer < ApplicationMailer
        def new_post(post_id)
          @post = Post.find(post_id)
          mail(to: "list@example.com")
        end
      end
    RUBY
    allow(graph).to receive(:node_exists?) { |id| %w[Post NotifySubscribersJob MailingListMailer].include?(id) }

    flow = assembler.assemble('NotifySubscribersJob#perform')
    expect(flow.steps.map do |step|
      step[:unit]
    end).to eq(['NotifySubscribersJob#perform', 'MailingListMailer#new_post', 'Post'])
    delivery = flow.steps.first[:operations].find { |op| op[:method] == 'deliver_later' }
    expect(delivery).to include(target: 'MailingListMailer.new_post', mailer_action: 'MailingListMailer#new_post')
  end

  it 'leaves a delivery on something that is not an indexed mailer alone' do
    write_unit('Notifier', type: 'service', source_code: "class Notifier\n  def self.ping = 1\nend\n")
    allow(graph).to receive(:node_exists?) { |id| %w[NotifySubscribersJob Notifier].include?(id) }
    write_unit('PingJob', type: 'job', source_code: "class PingJob\n  def perform = Notifier.ping.deliver_later\nend\n")

    delivery = assembler.assemble('PingJob#perform').steps.first[:operations].find do |op|
      op[:method] == 'deliver_later'
    end
    expect(delivery).not_to have_key(:mailer_action)
  end

  it 'narrows to one callback type for one event' do
    expect(callback_names(assembler.assemble('Post@after_commit(create)'))).to eq(%w[notify_subscribers reindex])
    expect(callback_names(assembler.assemble('Post@after_commit(destroy)'))).to eq(%w[purge_cache])
  end

  it 'takes one callback type across every event' do
    expect(callback_names(assembler.assemble('Post@after_commit'))).to eq(%w[notify_subscribers reindex purge_cache])
  end

  it 'runs the destroy chain without the save callbacks' do
    expect(callback_names(assembler.assemble('Post@destroy'))).to eq(%w[check_locked purge_cache])
  end

  it 'answers an empty flow for an unknown model, event or non-model unit' do
    expect(assembler.assemble('Nope@create').steps).to eq([])
    expect(assembler.assemble('Post@explode').steps).to eq([])
    expect(assembler.assemble('NotifySubscribersJob@create').steps).to eq([])
  end

  it 'parses the grammar and leaves other identifiers alone' do
    expect(described_class.model_event('Post@after_commit(create)')).to eq(%w[Post after_commit create])
    expect(described_class.model_event('Admin::Post@update')).to eq(['Admin::Post', nil, 'update'])
    expect(described_class.model_event('PostsController#create')).to be_nil
  end
end
