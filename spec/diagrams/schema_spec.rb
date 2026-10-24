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
end
