# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

# Boot this fixture in its own Rails-matrix process. It tests the real request
# environment, runtime controller extraction, disk reader and MCP response.
RSpec.describe 'Session controller identity', :booted_app do
  before(:all) do
    require 'logger'
    require 'rails'
    require 'action_controller/railtie'
    require 'rack/mock'
    require 'woods'
    require 'woods/session_tracer/middleware'
    require 'woods/session_tracer/file_store'
    require 'woods/session_tracer/session_flow_assembler'
    require 'woods/extractors/controller_extractor'
    require 'woods/mcp/server'

    @root = Dir.mktmpdir('woods-session-identity')
    @index = File.join(@root, 'index')
    @store = Woods::SessionTracer::FileStore.new(base_dir: File.join(@root, 'sessions'))
    write_controllers
    ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym 'API' }
    @app = Class.new(Rails::Application)
    @app.config.root = @root
    @app.config.eager_load = false
    @app.config.hosts.clear
    @app.config.public_file_server.enabled = false
    @app.config.secret_key_base = 'woods-synthetic-session-identity-fixture'
    @app.config.logger = Logger.new(File::NULL)
    @app.config.middleware.use Woods::SessionTracer::Middleware, store: @store
    @app.initialize!
    @app.routes.draw do
      get '/api/session_audit', to: 'api/session_audit#index'
      get '/session_audit', to: 'session_audit#index'
    end
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.session_store = @store
  end

  after(:all) do
    Woods.configuration = @original_config
    FileUtils.remove_entry(@root)
  end

  def write_controllers
    FileUtils.mkdir_p(File.join(@root, 'app/controllers/api'))
    File.write(File.join(@root, 'app/controllers/api/session_audit_controller.rb'), <<~SOURCE)
      module API
        class SessionAuditController < ActionController::Base
          def index
            render plain: 'acronym controller source marker'
          end
        end
      end
    SOURCE
    File.write(File.join(@root, 'app/controllers/session_audit_controller.rb'), <<~SOURCE)
      class SessionAuditController < ActionController::Base
        def index
          render plain: 'ordinary controller source marker'
        end
      end
    SOURCE
  end

  def publish_controller(controller)
    unit = Woods::Extractors::ControllerExtractor.new.extract_controller(controller)
    expect(unit.identifier).to eq(controller.name)
    filename = "#{unit.identifier.gsub('::', '__')}_#{Digest::SHA256.hexdigest(unit.identifier)[0, 8]}.json"
    write_index_json("controllers/#{filename}", unit.to_h)
    write_index_json('controllers/_index.json', [{ identifier: unit.identifier, type: 'controller' }])
    graph = Woods::DependencyGraph.new
    graph.register(unit)
    write_index_json('dependency_graph.json', graph.to_h)
    write_index_json('manifest.json', counts: { controllers: 1 })
  end

  def write_index_json(relative, data)
    path = File.join(@index, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def trace_response(session)
    server = Woods::MCP::Server.build(index_dir: @index, response_format: :json, warmup: false)
    request = {
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'session_trace', arguments: { session_id: session, depth: 1 } }
    }
    result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
    expect(result.fetch('isError')).to be false
    result.fetch('content').map { |part| part.fetch('text') }.join
  end

  [
    ['/api/session_audit', 'API::SessionAuditController', 'acronym controller source marker'],
    ['/session_audit', 'SessionAuditController', 'ordinary controller source marker']
  ].each do |path, identifier, marker|
    it "preserves #{identifier} from a real request through source-backed session_trace" do
      session = identifier.gsub('::', '-')
      response = Rack::MockRequest.new(@app).get(path, 'HTTP_X_TRACE_SESSION' => session)
      expect(response.status).to eq(200)
      expect(response.body).to eq(marker)
      controller = identifier.constantize
      publish_controller(controller)

      expect(@store.read(session).last.fetch('controller')).to eq(controller.name)
      document = Woods::SessionTracer::SessionFlowAssembler.new(
        store: @store, reader: Woods::MCP::IndexReader.new(@index)
      ).assemble(session)
      expect(document.context_pool.keys).to eq([identifier])
      expect(document.steps.first[:unit_refs]).to eq([identifier])
      expect(trace_response(session)).to include(identifier, 'def index', marker)
    end
  end
end
