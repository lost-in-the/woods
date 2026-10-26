# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/index_reader'
require 'woods/diagrams'

RSpec.describe Woods::Diagrams::Schema do
  include DiagramIndex

  before { Woods::Diagrams::Cache.clear }

  def build(**arguments)
    Woods::Diagrams.build(diagram_reader, kind: 'schema', **arguments)
  end

  it 'draws the table and one hop of associations by default, through associations left out' do
    expect(build(identifier: 'Post').text).to eq(<<~MERMAID.chomp)
      erDiagram
        "posts"
        "posts" }o--|| "users" : "author"
        "posts" ||--o{ "comments" : "comments"
    MERMAID
  end

  it 'adds the associations of the models each further hop reaches, each line once, up to depth 3' do
    expect(build(identifier: 'Comment', depth: 2).text).to eq(<<~MERMAID.chomp)
      erDiagram
        "comments"
        "comments" }o--|| "posts" : "post"
        "comments" }o--|| "users" : "user"
        "posts" }o--|| "users" : "author"
        "posts" ||--o{ "comments" : "comments"
        "users" ||--o{ "posts" : "posts"
        "users" ||--o{ "comments" : "comments"
    MERMAID
    expect(build(identifier: 'Comment', depth: 3).details).to include('depth' => 3, 'relationships' => 6)
    expect { build(identifier: 'Comment', depth: 4) }
      .to raise_error(Woods::Diagrams::InvalidRequest, /schema depth must be 1 to 3/)
  end

  it 'draws only models and database tables' do
    expect { build(identifier: 'NotifyJob') }
      .to raise_error(Woods::Diagrams::InvalidRequest, 'A schema diagram draws a model or database_table; ' \
                                                       'NotifyJob is a job')
  end

  it 'refuses a schema over its table budget with its size' do
    stub_const('Woods::Diagrams::Schema::TABLE_BUDGET', 2)
    result = build(identifier: 'Post')
    expect([result.text, result.refusal]).to eq([nil, '3 tables is over the ER budget of 2'])
    expect(result.details).to include('size' => 3, 'budget' => 2)
  end

  context 'with a database_table unit' do
    def table(name, foreign_keys = [])
      { 'identifier' => "table:#{name}", 'type' => 'database_table', 'file_path' => nil, 'source_code' => '',
        'metadata' => { 'table_name' => name, 'database' => 'primary', 'foreign_keys' => foreign_keys } }
    end

    def key(from, to, column, **actions)
      { 'from_table' => from, 'to_table' => to, 'column' => column, 'primary_key' => 'id' }.merge(actions)
    end

    let(:tables) do
      [table('users'),
       table('posts', [key('posts', 'users', 'author_id', 'on_delete' => 'cascade')]),
       table('comments', [key('comments', 'posts', 'post_id'), key('comments', 'users', 'user_id')]),
       table('categories', [key('categories', 'categories', 'parent_id')]),
       table('audits')]
    end
    let(:fk_edges) do
      [%w[table:posts foreign_key table:users], %w[table:comments foreign_key table:posts],
       %w[table:comments foreign_key table:users], %w[table:categories foreign_key table:categories]]
    end
    let(:fk_root) { Dir.mktmpdir('woods-diagrams-fk') }
    let(:fk_reader) do
      DiagramIndex.write(fk_root, units: DiagramIndex::UNITS + tables, edges: DiagramIndex::EDGES + fk_edges)
      Woods::MCP::IndexReader.new(fk_root)
    end

    after { FileUtils.remove_entry(fk_root) }

    def build_table(**arguments)
      Woods::Diagrams.build(fk_reader, kind: 'schema', **arguments)
    end

    it 'draws its outgoing foreign keys and the foreign keys that point at it, child on the many side' do
      expect(build_table(identifier: 'table:posts').text).to eq(<<~MERMAID.chomp)
        erDiagram
          "posts"
          "posts" }o--|| "users" : "author_id"
          "comments" }o--|| "posts" : "post_id"
      MERMAID
    end

    it 'adds the foreign keys of the tables each further hop reaches, each line once' do
      expect(build_table(identifier: 'table:posts', depth: 2).text).to eq(<<~MERMAID.chomp)
        erDiagram
          "posts"
          "posts" }o--|| "users" : "author_id"
          "comments" }o--|| "posts" : "post_id"
          "comments" }o--|| "users" : "user_id"
      MERMAID
    end

    it 'draws a self-referencing key once' do
      expect(build_table(identifier: 'table:categories').text).to eq(<<~MERMAID.chomp)
        erDiagram
          "categories"
          "categories" }o--|| "categories" : "parent_id"
      MERMAID
    end

    it 'draws a table with no foreign keys as its entity alone' do
      expect(build_table(identifier: 'table:audits').text).to eq("erDiagram\n  \"audits\"")
    end

    it 'counts the tables drawn against the budget and reports the relationships' do
      expect(build_table(identifier: 'table:posts').details).to include('table' => 'posts', 'relationships' => 2,
                                                                        'size' => 3)
    end

    it 'leaves a model unit in the same generation exactly as before' do
      expect(Woods::Diagrams.build(fk_reader, kind: 'schema', identifier: 'Post').text)
        .to eq(build(identifier: 'Post').text)
    end
  end
end
