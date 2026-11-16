# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

# Records each set_callback call on a controller class: the class, the
# filter and the application line that made it.
module PrependedFilterDeclarations
  def self.sites
    @sites ||= []
  end

  def set_callback(name, *filter_list, &block)
    if name == :process_action
      kind, filter = filter_list
      site = caller_locations.find { |location| location.absolute_path.to_s.start_with?("#{Rails.root}/") }
      PrependedFilterDeclarations.sites << { klass: self, kind: kind, filter: filter,
                                             site: site && [site.absolute_path, site.lineno] }
    end
    super
  end
end

# Controller filters declared with prepend_before_action and its siblings,
# compared with the real callback chain: in the controller, in a concern's
# included block, in a base controller (inherited, declared around, skipped
# with and without a scope), the around and after forms, append_ and the
# prepend: option, several names in one call, a block, a lambda, and
# only/except/if scopes. Every filter records its name as it runs, so each
# action's dispatch is the oracle for which filters run and in what order;
# a recorder on set_callback is the oracle for where Rails took each
# filter's declaration from.
RSpec.describe 'Prepended controller filter forms against the runtime chain', :booted_app do
  controllers = %w[LedgersController ReceiptsController EarlyAuditsController LateAuditsController
                   PortalController PortalDocumentsController PortalPagesController PortalPreviewsController
                   InstrumentsController AppendedStepsController BatchesController].freeze

  before(:all) do
    @root = Dir.mktmpdir('woods-prepended-filters')
    ENV['RAILS_ENV'] = 'test'
    require 'logger'
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'woods'
    require 'woods/extractor'
    require 'woods/flow_assembler'
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/prepended_filters', __dir__), '.'), @root)
    database = { 'test' => { 'adapter' => 'sqlite3', 'database' => ':memory:' } }
    File.write(File.join(@root, 'config', 'database.yml'), database.to_yaml)

    ActiveSupport.on_load(:action_controller_base) { singleton_class.prepend(PrependedFilterDeclarations) }
    @app = Object.const_set(:WoodsPrependedFiltersApplication, Class.new(Rails::Application))
    @app.config.root = @root
    @app.config.eager_load = false
    @app.config.secret_key_base = 'woods-prepended-filters-fixture'
    @app.config.logger = Logger.new(File::NULL)
    @app.initialize!
    Rails.application.eager_load!

    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.precompute_flows = true
    Woods.configuration.enable_snapshots = false
    @extractor = Woods::Extractor.new(output_dir: File.join(@root, 'index'))
    @results = @extractor.extract_all
    @extractor.raise_on_publication_failure!
  end

  after(:all) do
    Woods.configuration = @original_config if defined?(@original_config)
    FileUtils.remove_entry(@root) if @root
  end

  def unit_metadata(name)
    unit = @results.fetch(:controllers).find { |candidate| candidate.identifier == name }
    JSON.parse(JSON.generate(unit.metadata))
  end

  def raw_filter(callback)
    callback.respond_to?(:raw_filter) ? callback.raw_filter : callback.filter
  end

  # One name per filter on both sides: a method name, or `proc:<line>` for a
  # block or lambda (what the fixture's procs record when they run).
  def runtime_name(callback)
    filter = raw_filter(callback)
    filter.is_a?(Proc) ? "proc:#{filter.source_location.last}" : filter.to_s
  end

  def published_name(filter)
    filter.to_s[/\A#<(?:Proc|lambda) .+:(\d+)>\z/, 1]&.then { |line| "proc:#{line}" } || filter.to_s
  end

  def chain(klass)
    klass._process_action_callbacks.to_a
  end

  # The filter names an action's dispatch ran, in the order it ran them.
  def dispatched(klass, action)
    env = Rack::MockRequest.env_for("/#{action}")
    klass.action(action).call(env)
    env.fetch('filter_probe.trace', [])
  end

  # Where Rails took a callback's declaration from: the last set_callback
  # for its kind and filter on the class or a superclass, as
  # [root-relative file, line].
  def runtime_site(klass, callback)
    record = PrependedFilterDeclarations.sites.reverse.find do |entry|
      klass <= entry[:klass] && entry[:kind] == callback.kind && entry[:filter] == raw_filter(callback)
    end
    record&.dig(:site)&.then { |path, line| [path.delete_prefix("#{Rails.root}/"), line] }
  end

  # The set_callback calls made on the class itself (its own source or an
  # included concern's block) for this callback's kind and filter.
  def own_sites(klass, callback)
    PrependedFilterDeclarations.sites.select do |entry|
      entry[:klass].equal?(klass) && entry[:kind] == callback.kind && entry[:filter] == raw_filter(callback)
    end
  end

  # The actions a published entry's only/except lists admit, read the way a
  # flow reads them.
  def listed_actions(entry, actions)
    actions.select do |action|
      (entry['only'].nil? || entry['only'].include?(action)) && !Array(entry['except']).include?(action)
    end
  end

  def flow_operations(flow)
    JSON.parse(JSON.generate(flow)).fetch('steps').first.fetch('operations')
  end

  def on_demand_flow(identifier)
    Woods::FlowAssembler.new(graph: @extractor.dependency_graph, extracted_dir: @extractor.payload_dir)
                        .assemble(identifier).to_h
  end

  def precomputed_flow(identifier)
    flows = File.join(@extractor.payload_dir.to_s, 'flows')
    index = JSON.parse(File.read(File.join(flows, 'flow_index.json')))
    JSON.parse(File.read(File.join(@extractor.payload_dir.to_s, index.fetch(identifier))))
  end

  # The filter calls a flow lists: every action body is a `head(:ok)` response.
  def flow_filters(flow)
    flow_operations(flow).select { |op| op['type'] == 'call' }.map { |op| published_name(op['method']) }
  end

  controllers.each do |name|
    describe name do
      let(:klass) { name.constantize }
      let(:metadata) { unit_metadata(name) }
      let(:actions) { metadata.fetch('actions') }
      let(:runs) { actions.to_h { |action| [action, dispatched(klass, action)] } }

      it 'publishes the runtime chain in chain order, with each kind' do
        expect(metadata.fetch('filters').map { |entry| [entry['kind'], published_name(entry['filter'])] })
          .to eq(chain(klass).map { |callback| [callback.kind.to_s, runtime_name(callback)] })
      end

      it 'admits, through applies_to and through only/except, exactly the actions Rails runs each filter on' do
        metadata.fetch('filters').each do |entry|
          ran = actions.select { |action| runs.fetch(action).include?(published_name(entry['filter'])) }
          expect([entry['filter'], entry['applies_to']]).to eq([entry['filter'], ran])
          expect([entry['filter'], listed_actions(entry, actions)]).to eq([entry['filter'], ran])
        end
      end

      it 'records the declaration Rails kept for each filter' do
        metadata.fetch('filters').zip(chain(klass)).each do |entry, callback|
          expect([entry['filter'], entry.values_at('file', 'line')])
            .to eq([entry['filter'], runtime_site(klass, callback)])

          own = own_sites(klass, callback)
          declaration = entry['declaration']
          if own.one? && !raw_filter(callback).is_a?(Proc)
            path, line = own.first[:site]
            concern = File.basename(path, '.rb').camelize unless path.end_with?("/#{name.underscore}.rb")
            expect([entry['filter'], declaration&.values_at('file_line', 'file_unit')])
              .to eq([entry['filter'], [line, concern]])
          else
            expect([entry['filter'], declaration]).to eq([entry['filter'], nil])
          end
        end
      end

      it 'lists, in each action’s flow, the before filters Rails runs, in the order it runs them' do
        actions.each do |action|
          before = chain(klass).select { |callback| callback.kind == :before }.map { |callback| runtime_name(callback) }
          expected = runs.fetch(action) & before
          identifier = "#{name}##{action}"

          expect([action, flow_filters(on_demand_flow(identifier))]).to eq([action, expected])
          expect([action, flow_filters(precomputed_flow(identifier))]).to eq([action, expected])
        end
      end

      it 'attributes to each action the assigns of the before and around filters Rails runs for it' do
        actions.each do |action|
          ahead = chain(klass).select { |callback| %i[before around].include?(callback.kind) }
                              .map { |callback| runtime_name(callback) }
          attributed = metadata.dig('action_facts', action, 'assigns').map { |fact| fact['method'] }.uniq - [action]

          expect([action, attributed]).to eq([action, runs.fetch(action) & ahead.grep_v(/\Aproc:/)])
        end
      end
    end
  end

  it 'runs prepend_before_action :alpha, :beta as beta then alpha, ahead of the inherited filter' do
    expect(dispatched(BatchesController, 'index') & %w[alpha beta set_locale]).to eq(%w[beta alpha set_locale])
  end

  it 'runs after filters in the reverse of their chain order' do
    expect(chain(InstrumentsController).select { |callback| callback.kind == :after }.map(&:filter))
      .to eq(%i[flush_metrics record_view record_audit])
    expect(dispatched(InstrumentsController, 'show') & %w[flush_metrics record_view record_audit])
      .to eq(%w[record_audit record_view flush_metrics])
  end
end
