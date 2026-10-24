# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'woods'
require 'woods/extracted_unit'
require 'woods/extractors/shared_dependency_scanner'
require 'woods/extractors/route_helper_resolver'

# Route helper references (woods#795): each _path/_url helper a unit calls,
# resolved through the live named-route map, published beside the
# navigation edge, which keeps naming the controller only.
RSpec.describe Woods::Extractors::SharedDependencyScanner, 'route helper references' do
  let(:scanner_class) do
    Class.new do
      include Woods::Extractors::SharedDependencyScanner
      include Woods::Extractors::RouteHelperResolver

      def initialize(route_map)
        @route_helper_map = route_map
      end
    end
  end

  let(:route_map) do
    {
      'posts' => { controller: 'PostsController', action: 'index', path: '/posts', verb: 'GET' },
      'edit_post' => { controller: 'PostsController', action: 'edit', path: '/posts/:id/edit', verb: 'GET' },
      'post' => { controller: 'PostsController', action: 'show', path: '/posts/:id', verb: 'GET' },
      'users' => { controller: 'UsersController', action: 'index', path: '/users', verb: 'GET' }
    }
  end

  let(:scanner) { scanner_class.new(route_map) }
  let(:enabled) { true }

  before do
    Woods.configure unless Woods.configuration
    allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(enabled)
  end

  it 'keeps every helper that targets a controller, not only the first' do
    source = "link_to 'All', posts_path\nlink_to 'Edit', edit_post_path(@post)\nredirect_to users_url\n"

    expect(scanner.scan_route_helper_references(source)).to eq(
      [
        { helper: 'edit_post_path', route_name: 'edit_post', controller: 'PostsController', action: 'edit',
          verb: 'GET', path: '/posts/:id/edit', via: 'link_to' },
        { helper: 'posts_path', route_name: 'posts', controller: 'PostsController', action: 'index',
          verb: 'GET', path: '/posts', via: 'link_to' },
        { helper: 'users_url', route_name: 'users', controller: 'UsersController', action: 'index',
          verb: 'GET', path: '/users', via: 'link_to' }
      ]
    )
    expect(scanner.scan_navigation_dependencies(source).map { |d| d[:target] })
      .to eq(%w[PostsController UsersController])
  end

  it 'labels a form helper form_action and a controller redirect redirect_to' do
    source = "form_with(model: @post, url: post_path(@post)) do |f|\nend\n"
    refs = scanner.scan_route_helper_references(source)
    expect(refs.map { |r| [r[:helper], r[:via]] }).to contain_exactly(%w[post_path link_to], %w[post_path form_action])

    redirects = scanner.scan_route_helper_references('redirect_to posts_path', via_type: :redirect_to, forms: false)
    expect(redirects.map { |r| r[:via] }).to eq(['redirect_to'])
  end

  it 'records nothing for an unknown helper, a commented call or a helper the source defines' do
    source = "# posts_path\nlink_to 'x', missing_path\ndef users_url; end\nusers_url\n"
    expect(scanner.scan_route_helper_references(source)).to eq([])
  end

  it 'publishes the references on the unit and nothing when navigation edges are off' do
    unit = Woods::ExtractedUnit.new(type: :mailer, identifier: 'DigestMailer',
                                    file_path: 'app/mailers/digest_mailer.rb')
    unit.metadata = {}
    scanner.apply_route_helper_references(unit, 'link_to "x", posts_url')
    expect(unit.metadata[:route_helper_references].map { |r| r[:helper] }).to eq(['posts_url'])

    allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(false)
    unit.metadata = {}
    scanner.apply_route_helper_references(unit, 'link_to "x", posts_url')
    expect(unit.metadata).not_to have_key(:route_helper_references)
  end
end
