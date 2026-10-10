# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods'
require 'woods/extractor'
require 'woods/reload_policy'
require 'woods/mcp/index_reader'

# Registration of the database_table and external_consumer unit types in the
# shared tables every unit type has to appear in.
RSpec.describe 'Schema unit registration' do
  include_context 'isolated Woods runtime'

  let(:dispatcher) { Woods::PathDispatcher.new }

  before { Woods::PathDispatcher.reset! }
  after { Woods::PathDispatcher.reset! }

  it 'registers both extractors, their types, and their index directories' do
    expect(Woods::Extractor::EXTRACTORS).to include(
      database_tables: Woods::Extractors::DatabaseTableExtractor,
      external_consumers: Woods::Extractors::ExternalConsumerExtractor
    )
    expect(Woods::Extractor::TYPE_TO_EXTRACTOR_KEY).to include(database_table: :database_tables,
                                                               external_consumer: :external_consumers)
    expect(Woods::MCP::IndexReader::DIR_TO_TYPE).to include('database_tables' => 'database_table',
                                                            'external_consumers' => 'external_consumer')
  end

  it 're-runs both wholesale, and the units that resolve tables along with the table set' do
    expect(Woods::Extractor::WHOLE_APP_EXTRACTORS).to include(database_tables: :database_table,
                                                              external_consumers: :external_consumer)
    expect(Woods::Extractor::TABLE_CONSUMER_EXTRACTORS).to eq(%i[migrations database_views external_consumers])
  end

  %w[db/schema.rb db/structure.sql db/billing_schema.rb db/migrate/20240101000000_create_widgets.rb
     app/models/widget.rb].each do |path|
    it "re-runs tables when #{path} changes" do
      expect(dispatcher.whole_app_keys_for(path)).to include(:database_tables)
      expect(dispatcher.relevant?(path)).to be(true)
    end
  end

  it 'leaves tables alone for an unrelated change' do
    expect(dispatcher.whole_app_keys_for('app/services/widget_service.rb')).not_to include(:database_tables)
  end

  it 're-runs external consumers when the declared file changes, and only then' do
    Woods.configuration.external_table_consumers_path = 'config/woods/external_consumers.yml'

    expect(dispatcher.whole_app_keys_for('config/woods/external_consumers.yml')).to eq([:external_consumers])
    expect(dispatcher.whole_app_keys_for('config/woods/other.yml')).to eq([])
  end

  it 'serializes its dispatch rules identically in every process: names, never Procs' do
    rules = Woods::PathDispatcher.whole_app_rules.select do |rule|
      %i[database_tables external_consumers].include?(rule.extractor_key)
    end

    expect(rules.map(&:matcher)).to eq(%i[database_schema_path? external_consumers_path?])
    expect(JSON.parse(JSON.generate(rules.map(&:to_h)))).to eq(
      rules.map { |rule| rule.to_h.transform_keys(&:to_s).transform_values { |v| v.is_a?(Symbol) ? v.to_s : v } }
    )
  end

  describe 'ReloadPolicy' do
    let(:policy) { Woods::ReloadPolicy.new }

    it 'restarts for a per-database schema dump, like db/schema.rb' do
      expect(%w[db/schema.rb db/structure.sql db/billing_schema.rb db/billing_structure.sql]
               .map { |path| policy.classify(path) }).to eq(%i[restart restart restart restart])
    end

    it 're-extracts for a migration file' do
      expect(policy.classify('db/migrate/20240101000000_create_widgets.rb')).to eq(:reextract)
    end

    # The path sits outside `config_file_paths`, so only the declaration can
    # make it an input; YAML under config/ is a config_file source already.
    it 're-extracts for the declared external consumers file, and ignores it when undeclared' do
      expect(policy.classify('db/woods/external_consumers.yml')).to eq(:ignore)

      Woods.configuration.external_table_consumers_path = 'db/woods/external_consumers.yml'

      expect(policy.classify('db/woods/external_consumers.yml')).to eq(:reextract)
    end

    # Changed paths are uncontrolled input; the per-database dump pattern
    # must stay linear on a long near-match.
    ["db/#{'a_' * 50_000}", "db/#{'_schema.r' * 10_000}", "db/#{'a' * 50_000}/schema.rb"].each_with_index do |path, i|
      it "classifies adversarial dump-like path #{i + 1} within a second" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        policy.classify(path)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      end
    end

    it 'does not mistake other db files for schema dumps' do
      expect(%w[db/helpers/cleanup.rb db/schema.rb.bak db/nested/billing_schema.rb].map { |path| policy.classify(path) })
        .to eq(%i[ignore ignore ignore])
    end
  end
end
