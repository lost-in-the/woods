# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'woods/obsidian/name_mapper'
require 'woods/obsidian/note_builder'
# instance_double(Woods::Console::CredentialScanner) only verifies when the
# constant is loaded; require it here so the spec passes standalone.
require 'woods/console/credential_scanner'
require_relative '../fixtures/unblocked/golden_units'

RSpec.describe Woods::Obsidian::NoteBuilder do
  let(:nodes) do
    {
      'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb' },
      'Account' => { 'type' => 'model' },
      'Post' => { 'type' => 'model' },
      'WelcomeMailer' => { 'type' => 'mailer' },
      'UsersController' => { 'type' => 'controller' },
      'SyncJob' => { 'type' => 'job' }
    }
  end

  let(:mapper) do
    Woods::Obsidian::NameMapper.new(
      'User' => 'models', 'Account' => 'models', 'Post' => 'models',
      'WelcomeMailer' => 'mailers', 'UsersController' => 'controllers', 'SyncJob' => 'jobs'
    )
  end

  let(:pagerank) { { 'User' => 0.0421009876 } }
  let(:analysis) { { 'hubs' => [{ 'identifier' => 'User' }], 'cycles' => [], 'orphans' => [], 'bridges' => [] } }

  let(:builder) do
    described_class.new(name_mapper: mapper, nodes: nodes, pagerank: pagerank, analysis: analysis)
  end

  let(:user_unit) do
    {
      'identifier' => 'User', 'type' => 'model', 'file_path' => 'app/models/user.rb',
      'source_hash' => 'a3c5f8e9',
      'metadata' => {
        'loc' => 84, 'table_name' => 'users', 'column_count' => 17,
        'associations' => [
          { 'type' => 'has_many', 'target' => 'Post', 'options' => { 'dependent' => 'destroy' } },
          { 'type' => 'belongs_to', 'target' => 'Account' }
        ]
      }
    }
  end

  def build_user(depends_on: [], used_by: [])
    builder.build(id: 'User', unit: user_unit, depends_on: depends_on, used_by: used_by)
  end

  def frontmatter(note)
    YAML.safe_load(note.split("\n---\n").first)
  end

  describe 'frontmatter' do
    it 'emits flat, valid YAML frontmatter with the expected scalars' do
      fm = frontmatter(build_user)
      expect(fm).to include(
        'woods_managed' => true, 'id' => 'User', 'type' => 'model',
        'file' => 'app/models/user.rb', 'source_hash' => 'a3c5f8e9'
      )
      expect(fm['tags']).to include('woods/unit', 'woods/model', 'woods/hub')
    end

    it 'formats pagerank as a number rounded to 6 places' do
      fm = frontmatter(build_user)
      expect(fm['pagerank']).to eq(0.042101)
      expect(fm['pagerank']).to be_a(Numeric)
    end

    it 'records dependency and dependent counts' do
      note = build_user(depends_on: [{ target: 'Account', via: 'belongs_to' }], used_by: %w[UsersController])
      fm = frontmatter(note)
      expect(fm['dependency_count']).to eq(1)
      expect(fm['dependent_count']).to eq(1)
    end

    it 'survives a YAML-hostile identifier (quotes, colon, hash, newline)' do
      hostile = %(Weird"Name: with #hash\nand newline)
      nodes[hostile] = { 'type' => 'model' }
      m = Woods::Obsidian::NameMapper.new(hostile => 'models')
      b = described_class.new(name_mapper: m, nodes: nodes)
      note = b.build(id: hostile, unit: { 'identifier' => hostile, 'type' => 'model' }, depends_on: [], used_by: [])
      expect { frontmatter(note) }.not_to raise_error
      expect(frontmatter(note)['id']).to eq(hostile)
    end

    it 'omits keys with no value rather than emitting null' do
      note = builder.build(id: 'Account', unit: { 'identifier' => 'Account', 'type' => 'model' },
                           depends_on: [], used_by: [])
      expect(frontmatter(note)).not_to have_key('file')
      expect(note).not_to match(/file:\s*$/)
    end
  end

  describe 'body' do
    it 'opens with a clean H1 carrying the original identifier' do
      note = builder.build(id: 'UsersController',
                           unit: { 'identifier' => 'Users::RegistrationsController', 'type' => 'controller' },
                           depends_on: [], used_by: [])
      expect(note).to match(/\n# Users::RegistrationsController\n/)
    end

    it 'renders "Depends on" as wikilinks with the via label, sorted' do
      note = build_user(depends_on: [
                          { target: 'WelcomeMailer', via: 'job_enqueue' },
                          { target: 'Account', via: 'belongs_to' }
                        ])
      expect(note).to include('## Depends on')
      expect(note).to include('[[models/Account|Account]] — *belongs_to*')
      expect(note).to include('[[mailers/WelcomeMailer|WelcomeMailer]] — *job_enqueue*')
      # sorted: Account before WelcomeMailer
      expect(note.index('Account')).to be < note.index('WelcomeMailer')
    end

    it 'renders "Used by" grouped by source type with wikilinks' do
      note = build_user(used_by: %w[UsersController SyncJob])
      expect(note).to match(/## Used by \(2\)/)
      expect(note).to include('**controllers:**')
      expect(note).to include('[[controllers/UsersController|UsersController]]')
      expect(note).to include('**jobs:**')
    end

    it 'flags a hub with a built-in callout' do
      expect(build_user).to match(/> \[!warning\] Hub/)
    end

    it 'renders model associations, linking only targets that have notes' do
      note = build_user
      expect(note).to include('## Associations')
      expect(note).to include('[[models/Post|Post]]')
      expect(note).to include('(dependent: destroy)')
    end

    it 'renders a schema section for a model with enums/scopes/concerns/callbacks (via UnitFacts)' do
      unit = user_unit.merge('metadata' => user_unit['metadata'].merge(
        'enums' => { 'status' => %w[a b] },
        'scopes' => [{ 'name' => 'recent' }],
        'inlined_concerns' => %w[Auditable],
        'callbacks' => [{ 'type' => 'before_save', 'filter' => 'normalize' }]
      ))
      note = builder.build(id: 'User', unit: unit, depends_on: [], used_by: [])
      expect(note).to include('## Schema', '**Enums:** status', '**Scopes:** recent',
                              '**Concerns:** Auditable', '**Callbacks:** before_save normalize')
    end

    it 'does not emit a dangling wikilink for an unknown dependency target' do
      note = build_user(depends_on: [{ target: 'NotExported', via: 'code_reference' }])
      expect(note).not_to include('NotExported')
    end
  end

  describe 'source inclusion' do
    # A scanner double honoring the CredentialScanner contract: scan(value)
    # returns [scrubbed, counts]. Keeps the test independent of which exact
    # patterns the real scanner ships.
    let(:scanner) do
      instance_double(Woods::Console::CredentialScanner).tap do |s|
        allow(s).to receive(:scan) { |v| [v.gsub('SECRET', '[REDACTED]'), {}] }
      end
    end

    def build_with_source(scanner:, source:)
      described_class.new(name_mapper: mapper, nodes: nodes, pagerank: pagerank,
                          analysis: analysis, include_source: true, scanner: scanner)
                     .build(id: 'User', unit: user_unit.merge('source_code' => source), depends_on: [], used_by: [])
    end

    it 'omits the source section by default' do
      expect(build_user).not_to include('## Source')
    end

    it 'includes credential-scrubbed source when enabled' do
      note = build_with_source(scanner: scanner, source: "class User\n  KEY = 'SECRET'\nend")
      expect(note).to include('## Source')
      expect(note).to include('```ruby')
      expect(note).to include('[REDACTED]')
      expect(note).not_to match(/'SECRET'/)
    end

    it 'omits the source section when the scrub raises — never ships unscrubbed source' do
      raising = instance_double(Woods::Console::CredentialScanner)
      allow(raising).to receive(:scan).and_raise(StandardError, 'scanner boom')
      note = build_with_source(scanner: raising, source: "class User\n  KEY = 'SECRET'\nend")
      expect(note).not_to be_nil
      expect(note).not_to include('## Source')
      expect(note).not_to match(/SECRET/)
    end
  end

  describe 'determinism' do
    it 'produces identical output across builds' do
      args = { depends_on: [{ target: 'Account', via: 'belongs_to' }], used_by: %w[UsersController SyncJob] }
      expect(build_user(**args)).to eq(build_user(**args))
    end
  end

  # Cross-checks the SAME fixture the Unblocked golden suite uses (GoldenUnits),
  # so a change to a unit type's metadata shape breaks both spec suites — the
  # drift guard for the shared UnitFacts layer (B-057).
  describe 'shared metadata-shape fixture' do
    let(:fixture_mapper) do
      Woods::Obsidian::NameMapper.new(%w[Order User LineItem Payment Invoice].to_h { |t| [t, 'models'] })
    end

    it 'renders the shared model fixture associations + schema through UnitFacts' do
      note = described_class.new(name_mapper: fixture_mapper, nodes: {})
                            .build(id: 'Order', unit: GoldenUnits.model, depends_on: [], used_by: [])
      expect(note).to include(
        '## Associations',
        '[[models/User|User]]',
        '[[models/LineItem|LineItem]] (dependent: destroy)',
        '## Schema', '**Enums:** status', '**Concerns:** Auditable, Timestamps'
      )
    end
  end
end
