# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
ENV['WOODS_DUMMY_DB'] ||= File.join(Dir.tmpdir, "woods-association-count-#{Process.pid}.sqlite3")
require_relative 'support/booted_console_app' if ENV['WOODS_RUN_BOOTED_APP']
require 'woods/console/server'

RSpec.describe 'Console association counts through real Active Record', :booted_app do
  let(:models) { [AssociationParent, AssociationChild] }
  let(:model_tables) { models.to_h { |model| [model.name, model.table_name] } }
  let(:server) do
    Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(
        registry: models.to_h { |model| [model.name, model.column_names] }, table_names: model_tables
      ),
      safe_context: Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool),
      model_tables: model_tables,
      model_reflections: models.to_h do |model|
        [model.name, model.reflect_on_all_associations.to_h do |reflection|
          [reflection.name.to_s, reflection.klass.table_name]
        end]
      end
    )
  end

  before do
    @configuration = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.context_format = :json
    stub_const('AssociationParent', Class.new(ActiveRecord::Base))
    stub_const('AssociationChild', Class.new(ActiveRecord::Base))
    AssociationParent.table_name = 'posts'
    AssociationChild.table_name = 'comments'
    AssociationParent.has_many :children, class_name: 'AssociationChild', foreign_key: :post_id
    AssociationParent.has_one :child, class_name: 'AssociationChild', foreign_key: :post_id
    AssociationChild.belongs_to :parent, class_name: 'AssociationParent', foreign_key: :post_id, optional: true
    AssociationChild.delete_all
    AssociationParent.delete_all
    AssociationParent.create!(id: 1, title: 'First', status: 1)
    AssociationParent.create!(id: 2, title: 'Empty', status: 0)
    AssociationChild.create!(id: 1, post_id: 1, body: 'First')
    AssociationChild.create!(id: 2, post_id: 1, body: 'Second')
    AssociationChild.create!(id: 3, post_id: nil, body: 'Orphan')
  end

  after { Woods.configuration = @configuration }

  def call_count(model:, id:, association:, **options)
    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: {
                              name: 'console_association_count', arguments: { model: model, id: id,
                                                                              association: association, **options }
                            })
    JSON.parse(server.handle_json(request)).fetch('result')
  end

  def expect_count(expected, **arguments)
    result = call_count(**arguments)
    expect(result.fetch('isError')).to be(false), result.inspect
    expect(JSON.parse(result.dig('content', 0, 'text'))).to eq('count' => expected)
  end

  it 'counts a present belongs_to as one' do
    expect_count(1, model: 'AssociationChild', id: 1, association: 'parent')
  end

  it 'counts a missing belongs_to as zero' do
    expect_count(0, model: 'AssociationChild', id: 3, association: 'parent')
  end

  it 'counts a present has_one as one even if multiple rows match its foreign key' do
    expect_count(1, model: 'AssociationParent', id: 1, association: 'child')
  end

  it 'counts a missing has_one as zero' do
    expect_count(0, model: 'AssociationParent', id: 2, association: 'child')
  end

  it 'applies the requested scope to a belongs_to target relation' do
    expect_count(1, model: 'AssociationChild', id: 1, association: 'parent', scope: { status: 1 })
    expect_count(0, model: 'AssociationChild', id: 1, association: 'parent', scope: { status: 0 })
  end

  it 'applies the requested scope to a has_one target relation' do
    expect_count(1, model: 'AssociationParent', id: 1, association: 'child', scope: { body: 'First' })
    expect_count(0, model: 'AssociationParent', id: 1, association: 'child', scope: { body: 'Absent' })
  end

  it 'preserves collection counts and scoped collection counts' do
    expect_count(2, model: 'AssociationParent', id: 1, association: 'children')
    expect_count(1, model: 'AssociationParent', id: 1, association: 'children', scope: { body: 'First' })
  end

  it 'refuses a blocked singular target before reading either table' do
    Woods.configuration.console_blocked_tables = ['posts']
    server
    queries = []
    callback = ->(*arguments) { queries << arguments.last.fetch(:sql) }
    result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      call_count(model: 'AssociationChild', id: 1, association: 'parent')
    end

    expect(result.fetch('isError')).to be(true)
    expect(result.dig('content', 0, 'text')).to include('blocked', 'posts')
    expect(queries.grep(/\bSELECT\b/i)).to be_empty
  end

  it 'validates singular target scope columns before parent lookup' do
    server
    queries = []
    callback = ->(*arguments) { queries << arguments.last.fetch(:sql) }
    result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      call_count(model: 'AssociationChild', id: 1, association: 'parent', scope: { missing: 1 })
    end

    expect(result.fetch('isError')).to be(true)
    expect(result.dig('content', 0, 'text')).to include("Unknown column 'missing'")
    expect(queries.grep(/\bSELECT\b/i)).to be_empty
  end
end
