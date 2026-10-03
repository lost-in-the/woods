# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/test_route_resolver'

RSpec.describe Woods::Extractors::TestRouteResolver do
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }
  let(:routes) do
    [
      route_double(verb: 'GET', path: '/', controller: 'home', action: 'show', name: 'root'),
      route_double(verb: 'GET', path: '/widgets', controller: 'widgets', action: 'index', name: 'widgets'),
      route_double(verb: 'POST', path: '/widgets', controller: 'widgets', action: 'create'),
      route_double(verb: 'GET', path: '/widgets/new', controller: 'widgets', action: 'new', name: 'new_widget'),
      route_double(verb: 'GET', path: '/widgets/:id', controller: 'widgets', action: 'show', name: 'widget'),
      route_double(verb: 'PATCH', path: '/widgets/:id', controller: 'widgets', action: 'update'),
      route_double(verb: 'DELETE', path: '/widgets/:id', controller: 'widgets', action: 'destroy'),
      route_double(verb: 'GET', path: '/ledgers/:ledger_id/entries(/:page)', controller: 'ledger/entries',
                   action: 'index', name: 'ledger_entries'),
      route_double(verb: 'GET', path: '/files/*path', controller: 'files', action: 'show', name: 'file'),
      route_double(verb: 'GET', path: '/api/widgets', controller: 'api/widgets', action: 'index',
                   constraints: { subdomain: 'api' })
    ]
  end

  before { stub_route_set(routes, root: Pathname.new(Dir.tmpdir), logger: logger) }

  def exercised(source)
    described_class.new.exercised(source)
  end

  it 'resolves visit with a route helper' do
    expect(exercised("visit new_widget_path\nvisit widget_url(widget)\n")).to eq(['GET /widgets/:id',
                                                                                  'GET /widgets/new'])
  end

  it 'resolves a request verb with a route helper to the route for that verb' do
    source = "post widgets_path, params: { widget: {} }\ndelete widget_path(widget)\npatch(widget_path(widget))\n"

    expect(exercised(source)).to eq(['DELETE /widgets/:id', 'PATCH /widgets/:id', 'POST /widgets'])
  end

  it 'resolves literal paths in either quote style' do
    expect(exercised(%(visit "/widgets"\nget '/widgets/new'\npost("/widgets")\n)))
      .to eq(['GET /widgets', 'GET /widgets/new', 'POST /widgets'])
  end

  it 'matches a literal against dynamic segments in route order' do
    expect(exercised(%(get "/widgets/42"\nget "/widgets/new"\n))).to eq(['GET /widgets/:id', 'GET /widgets/new'])
  end

  it 'treats an interpolation as one path segment value' do
    source = <<~'RUBY'
      visit "/widgets/#{widget.id}"
      get "/ledgers/#{ledger.id}/entries/#{page}"
    RUBY

    expect(exercised(source)).to eq(['GET /ledgers/:ledger_id/entries(/:page)', 'GET /widgets/:id'])
  end

  it 'ignores the query string, fragment, format, and a trailing slash' do
    source = %(visit "/widgets?page=2"\nvisit "/widgets/7.json"\nvisit "/widgets/new#form"\nvisit "/widgets/"\n)

    expect(exercised(source)).to eq(['GET /widgets', 'GET /widgets/:id', 'GET /widgets/new'])
  end

  it 'resolves the root path and optional and glob segments' do
    expect(exercised(%(visit "/"\nvisit root_path\nget "/ledgers/3/entries"\nget "/files/a/b/c.txt"\n)))
      .to eq(['GET /', 'GET /files/*path', 'GET /ledgers/:ledger_id/entries(/:page)'])
  end

  it 'matches the literal root path without a helper' do
    expect(exercised(%(visit "/"\n))).to eq(['GET /'])
  end

  it 'uses the identifier the route unit carries, constraints included' do
    expect(exercised(%(get "/api/widgets"\n))).to eq(['GET /api/widgets [subdomain=api]'])
  end

  it 'accepts page.visit and main_app helpers' do
    expect(exercised("page.visit widgets_path\nvisit main_app.new_widget_path\n"))
      .to eq(['GET /widgets', 'GET /widgets/new'])
  end

  it 'emits nothing for an unknown helper, an unrouted path, or a verb the path does not accept' do
    expect(exercised(%(visit ghost_path\nvisit "/nowhere"\ndelete widgets_path\nput "/widgets"\n))).to eq([])
  end

  it 'ignores commented calls, other receivers, symbols, and absolute URLs' do
    source = <<~RUBY
      # visit widgets_path
      cache.get "/widgets"
      get :index
      visit "https://example.test/widgets"
      target = widget_path(widget)
      @client.post "/widgets"
    RUBY

    expect(exercised(source)).to eq([])
  end

  it 'skips a literal whose interpolation holds a quote' do
    source = <<~'RUBY'
      visit "/widgets/#{params["id"]}"
    RUBY

    expect(exercised(source)).to eq([])
  end

  it 'returns nothing when the route set is unavailable' do
    stub_const('Rails', double('Rails', root: Pathname.new(Dir.tmpdir), logger: logger))

    expect(exercised("visit widgets_path\n")).to eq([])
  end
end
