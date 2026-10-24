# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/index_reader'
require 'woods/diagrams'

RSpec.describe Woods::Diagrams::Lifecycle do
  include DiagramIndex

  before { Woods::Diagrams::Cache.clear }

  def build(**arguments)
    Woods::Diagrams.build(diagram_reader, kind: 'lifecycle', **arguments)
  end

  it 'draws the create chain at depth 0 by default: own and concern callbacks, the async step handing off' do
    result = build(identifier: 'Post')
    expect(result.text).to eq(<<~MERMAID.chomp)
      sequenceDiagram
        autonumber
        participant App
        participant M as Post
        participant A0 as NotifyJob
        App->>M: before_save set_slug
        App->>M: before_save normalize_tags
        M-)A0: notify_followers
    MERMAID
    expect(result.details).to include('event' => 'create', 'depth' => 0, 'steps' => 3, 'framework_callbacks' => 1,
                                      'participants' => ['NotifyJob'], 'followed' => [])
  end

  it 'leaves out callbacks scoped to another event' do
    expect(build(identifier: 'Post', event: 'update').text).not_to include('notify_followers')
    expect { build(identifier: 'Post', event: 'touch') }
      .to raise_error(Woods::Diagrams::InvalidRequest, /event must be one of create, update, destroy/)
  end

  it 'follows the async hops into the jobs and mailers they reach at depth 2' do
    result = build(identifier: 'Post', depth: 2)
    expect(result.text).to eq(<<~MERMAID.chomp)
      sequenceDiagram
        autonumber
        participant App
        participant M as Post
        participant A0 as NotifyJob
        participant A1 as DigestMailer
        participant A2 as AuditJob
        App->>M: before_save set_slug
        App->>M: before_save normalize_tags
        M-)A0: notify_followers
        A0->>A0: Post.find
        A0-)A1: weekly (deliver_later)
        A0-)A2: perform_later
        A1->>A1: mail
        A2->>A2: User.find.touch
    MERMAID
    expect(result.details['followed']).to eq(%w[NotifyJob#perform DigestMailer#weekly AuditJob#perform])
  end

  it 'draws the last depth\'s hand-offs without following them' do
    text = build(identifier: 'Post', depth: 1).text
    expect(text).to include('A0-)A1: weekly (deliver_later)', 'A0-)A2: perform_later')
    expect(text).not_to include('A1->>A1', 'A2->>A2')
    expect { build(identifier: 'Post', depth: 3) }
      .to raise_error(Woods::Diagrams::InvalidRequest, /lifecycle depth must be 0 to 2/)
  end

  it 'follows a mailer into the action its delivery names' do
    expect(build(identifier: 'User', depth: 1).text).to end_with("M-)A0: send_welcome\n  A0->>A0: mail")
  end

  it 'draws a mailer it cannot tell the action of, without following it, and names it' do
    units = DiagramIndex::UNITS.map do |unit|
      case unit['identifier']
      when 'DigestMailer' then unit.merge('metadata' => { 'actions' => %w[weekly monthly] })
      when 'User'
        callbacks = unit.dig('metadata', 'callbacks').map do |cb|
          cb.merge('side_effects' => cb['side_effects'].except('operations'))
        end
        unit.merge('metadata' => unit['metadata'].merge('callbacks' => callbacks))
      else unit
      end
    end
    Dir.mktmpdir('woods-diagrams-mailer') do |root|
      reader = Woods::MCP::IndexReader.new(DiagramIndex.write(root, units: units))
      result = Woods::Diagrams.build(reader, kind: 'lifecycle', identifier: 'User', depth: 1)
      expect(result.text).to end_with('M-)A0: send_welcome')
      expect(result.details).to include('followed' => [], 'unfollowed' => ['DigestMailer'])
    end
  end

  it 'draws only models' do
    expect { build(identifier: 'DigestMailer') }
      .to raise_error(Woods::Diagrams::InvalidRequest, /draws a model; DigestMailer is a mailer/)
  end

  it 'refuses a lifecycle over its sequence budget with its size' do
    stub_const('Woods::Diagrams::Lifecycle::SEQUENCE_BUDGET', 10)
    expect(build(identifier: 'Post')).to be_drawn
    result = build(identifier: 'Post', depth: 2)
    expect([result.text, result.refusal])
      .to eq([nil, '13 participants and messages is over the sequence budget of 10'])
  end
end
