# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'

# The published source of the diagram fixture's units.
module DiagramIndexSources
  POST_SOURCE = <<~RUBY
    class Post < ApplicationRecord
      include Taggable
      belongs_to :author, class_name: 'User'
      has_many :comments
      before_save :set_slug
      after_commit :notify_followers, on: :create

      def set_slug
        self.slug = title.parameterize
      end

      def notify_followers
        NotifyJob.perform_later(id)
      end
    end
  RUBY

  USER_SOURCE = <<~RUBY
    class User < ApplicationRecord
      has_many :posts, foreign_key: :author_id
      has_many :comments
      after_create_commit :send_welcome

      def send_welcome
        DigestMailer.weekly(self).deliver_later
      end
    end
  RUBY

  JOB_SOURCE = <<~RUBY
    class NotifyJob < ApplicationJob
      def perform(id)
        post = Post.find(id)
        DigestMailer.weekly(post).deliver_later
        AuditJob.perform_later(id)
      end
    end
  RUBY

  AUDIT_SOURCE = <<~RUBY
    class AuditJob < ApplicationJob
      def perform(id)
        User.find(id).touch
      end
    end
  RUBY

  MAILER_SOURCE = <<~RUBY
    class DigestMailer < ApplicationMailer
      def weekly(record)
        @record = record
        mail(to: 'digest@example.com')
      end
    end
  RUBY
end

# One published generation for the diagram builders (woods#826): three models
# with associations and callbacks, a concern, two jobs and a mailer, so every
# kind has something to draw and the lifecycle has two async hops to follow
# (Post@create enqueues NotifyJob, which mails DigestMailer#weekly and
# enqueues AuditJob).
module DiagramIndex # rubocop:disable Metrics/ModuleLength -- the fixture's units, edges and writer
  include DiagramIndexSources

  def self.association(type, name, target, foreign_key, **extra)
    { 'type' => type, 'name' => name, 'target' => target, 'foreign_key' => foreign_key }.merge(extra)
  end

  def self.callback(type, filter, conditions: {}, side_effects: {})
    { 'type' => type, 'filter' => filter, 'conditions' => conditions, 'side_effects' => side_effects }
  end

  UNITS = [
    { 'identifier' => 'Post', 'type' => 'model', 'file_path' => 'app/models/post.rb', 'source_code' => POST_SOURCE,
      'metadata' => {
        'table_name' => 'posts', 'inlined_concerns' => ['Taggable'],
        'associations' => [association('belongs_to', 'author', 'User', 'author_id'),
                           association('has_many', 'comments', 'Comment', 'post_id'),
                           association('has_many', 'tags', 'Tag', nil, 'through' => 'taggings')],
        'callbacks' => [
          callback('before_validation', 'normalize_changed_in_place_attributes'),
          callback('before_save', 'set_slug', side_effects: { 'columns_written' => ['slug'] }),
          callback('before_save', 'normalize_tags'),
          callback('after_save', '_run_internal_hook'),
          callback('after_commit', 'notify_followers',
                   conditions: { 'on' => ['create'] },
                   side_effects: { 'jobs_enqueued' => ['NotifyJob'],
                                   'operations' => [{ 'type' => 'async', 'target' => 'NotifyJob',
                                                      'method' => 'perform_later' }] })
        ]
      } },
    { 'identifier' => 'User', 'type' => 'model', 'file_path' => 'app/models/user.rb', 'source_code' => USER_SOURCE,
      'metadata' => {
        'table_name' => 'users',
        'associations' => [association('has_many', 'posts', 'Post', 'author_id'),
                           association('has_many', 'comments', 'Comment', 'user_id')],
        'callbacks' => [
          callback('after_create_commit', 'send_welcome',
                   side_effects: { 'mailers_triggered' => ['DigestMailer'],
                                   'operations' => [{ 'type' => 'call', 'target' => 'DigestMailer.weekly',
                                                      'method' => 'deliver_later',
                                                      'mailer_action' => 'DigestMailer#weekly' }] })
        ]
      } },
    { 'identifier' => 'Comment', 'type' => 'model', 'file_path' => 'app/models/comment.rb',
      'source_code' => "class Comment < ApplicationRecord\n  belongs_to :post\n  belongs_to :user\nend\n",
      'metadata' => { 'table_name' => 'comments',
                      'associations' => [association('belongs_to', 'post', 'Post', 'post_id'),
                                         association('belongs_to', 'user', 'User', 'user_id')] } },
    { 'identifier' => 'Taggable', 'type' => 'concern', 'file_path' => 'app/models/concerns/taggable.rb',
      'source_code' => "module Taggable\n  def normalize_tags\n  end\nend\n",
      'metadata' => { 'instance_methods' => ['normalize_tags'] } },
    { 'identifier' => 'NotifyJob', 'type' => 'job', 'file_path' => 'app/jobs/notify_job.rb',
      'source_code' => JOB_SOURCE, 'metadata' => {} },
    { 'identifier' => 'AuditJob', 'type' => 'job', 'file_path' => 'app/jobs/audit_job.rb',
      'source_code' => AUDIT_SOURCE, 'metadata' => {} },
    { 'identifier' => 'DigestMailer', 'type' => 'mailer', 'file_path' => 'app/mailers/digest_mailer.rb',
      'source_code' => MAILER_SOURCE, 'metadata' => { 'actions' => ['weekly'] } }
  ].freeze

  # [source, via, target] for every published edge.
  EDGES = [
    %w[Post belongs_to User], %w[Post has_many Comment], %w[Post job_enqueue NotifyJob], %w[Post include Taggable],
    %w[User has_many Post], %w[User has_many Comment], %w[User mailer_call DigestMailer],
    %w[Comment belongs_to Post], %w[Comment belongs_to User],
    %w[NotifyJob code_reference Post], %w[NotifyJob mailer_call DigestMailer], %w[NotifyJob job_enqueue AuditJob],
    %w[AuditJob code_reference User]
  ].freeze

  module_function

  # @param root [String] an empty directory
  # @param units [Array<Hash>]
  # @param edges [Array<Array(String, String, String)>]
  # @return [String] the index root
  def write(root, units: UNITS, edges: EDGES)
    payload = File.join(root, 'payloads', 'gen-1')
    groups = units.group_by { |unit| Woods::MCP::IndexReader::TYPE_TO_DIR.fetch(unit['type']) }
    groups.each { |dir, records| write_units(File.join(payload, dir), records) }
    File.write(File.join(payload, 'manifest.json'),
               JSON.generate('total_units' => units.size, 'counts' => groups.transform_values(&:size),
                             'extracted_at' => '2026-10-24T00:00:00Z'))
    File.write(File.join(payload, 'dependency_graph.json'), JSON.generate(graph(units, edges)))
    File.write(File.join(root, 'generation.json'), JSON.generate('number' => 1, 'token' => 'diagrams-1',
                                                                 'payload' => 'payloads/gen-1'))
    root
  end

  def write_units(dir, records)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '_index.json'), JSON.generate(records.map { |u| u.slice('identifier', 'file_path') }))
    records.each do |unit|
      id = unit['identifier']
      base = id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
      File.write(File.join(dir, "#{base}_#{Digest::SHA256.hexdigest(id)[0, 8]}.json"),
                 JSON.generate(unit.merge('dependencies' => [], 'dependents' => [])))
    end
  end

  def graph(units, edges) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    types = units.to_h { |u| [u['identifier'], u['type']] }
    forward, reverse_via = graph_edges(types, edges)
    { 'nodes' => graph_nodes(units), 'edges' => units.to_h { |u| [u['identifier'], forward[u['identifier']]] },
      'reverse' => reverse_via.transform_values { |list| list.map { |e| e['source'] }.uniq },
      'reverse_via' => reverse_via, 'file_map' => {},
      'type_index' => units.group_by { |u| u['type'] }.transform_values { |list| list.map { |u| u['identifier'] } },
      'pagerank' => units.to_h { |u| [u['identifier'], 0.1] } }
  end

  def graph_nodes(units)
    units.to_h do |u|
      node = { 'type' => u['type'], 'file_path' => u['file_path'] }
      node['table'] = u.dig('metadata', 'table_name') if u['type'] == 'model'
      [u['identifier'], node]
    end
  end

  def graph_edges(types, edges)
    forward = Hash.new { |h, k| h[k] = [] }
    reverse_via = Hash.new { |h, k| h[k] = [] }
    edges.each do |source, via, target|
      forward[source] << { 'target' => target, 'via' => via, 'type' => types[target] }
      reverse_via[target] << { 'source' => source, 'source_type' => types[source], 'via' => via }
    end
    [forward, reverse_via]
  end

  # A fresh index root for one example.
  def self.included(group)
    group.around do |example|
      Dir.mktmpdir('woods-diagrams') do |root|
        @diagram_root = DiagramIndex.write(root)
        example.run
      end
    end
  end

  attr_reader :diagram_root

  # @return [Woods::MCP::IndexReader] pinned to the fixture's generation
  def diagram_reader
    @diagram_reader ||= Woods::MCP::IndexReader.new(diagram_root)
  end
end
