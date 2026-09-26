# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'rack/mock'
require 'rack/request'
require 'woods/console/rack_middleware'

RSpec.describe 'Console middleware mount policy' do
  let(:configuration) { Woods::Configuration.new }
  let(:token) { 'synthetic-local-token-' * 3 }
  let(:middleware) { Woods::Console::RackMiddleware.new(->(_env) { [204, {}, []] }, path: '/custom/console') }
  let(:transport) { double(handle_request: [200, {}, ['fixture']]) }

  before do
    allow(Woods).to receive(:configuration).and_return(configuration)
    allow(Woods.configuration).to receive(:console_mcp_enabled).and_return(true)
    allow(Woods.configuration).to receive(:console_mcp_token).and_return(token)
    allow(Woods.configuration).to receive(:console_mcp_allowed_origins).and_return([])
    allow(middleware).to receive(:ensure_transport).and_return(transport)
  end

  def request(**headers)
    middleware.call(Rack::MockRequest.env_for('/custom/console', { 'HTTP_HOST' => 'localhost' }.merge(headers)))
  end

  it 'refuses an unauthenticated manual mount before building its transport' do
    expect(request.first).to eq(401)
    expect(middleware).not_to have_received(:ensure_transport)
  end

  it 'uses current credentials on every request and refuses missing or short configuration' do
    expect(request('HTTP_AUTHORIZATION' => "Bearer #{token}").first).to eq(200)
    [nil, '', 'short', 'different-valid-token-' * 3].each do |replacement|
      allow(Woods.configuration).to receive(:console_mcp_token).and_return(replacement)
      expect(request('HTTP_AUTHORIZATION' => "Bearer #{token}").first).to eq(401)
    end
  end

  it 'validates enabled manual-mount origin configuration during construction' do
    allow(Woods.configuration).to receive(:console_mcp_allowed_origins).and_return(['invalid-entry'])
    expect { Woods::Console::RackMiddleware.new(->(_env) { [204, {}, []] }) }
      .to raise_error(ArgumentError, /Invalid MCP allowed origin/)
  end

  it 'refuses a hostile origin or host before dispatch even with valid authentication' do
    expect(request('HTTP_AUTHORIZATION' => "Bearer #{token}",
                   'HTTP_ORIGIN' => 'https://foreign.invalid').first).to eq(403)
    expect(request('HTTP_AUTHORIZATION' => "Bearer #{token}", 'HTTP_HOST' => 'foreign.invalid').first).to eq(403)
    expect(middleware).not_to have_received(:ensure_transport)
  end

  it 'preserves disabled 410 behavior and passes unrelated host routes through' do
    allow(Woods.configuration).to receive(:console_mcp_enabled).and_return(false)
    expect(request.first).to eq(410)
    expect(middleware.call(Rack::MockRequest.env_for('/ordinary')).first).to eq(204)
  end
end
