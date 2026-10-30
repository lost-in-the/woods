# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/test_request_host'
require 'woods/extractors/test_mapping_extractor'
require 'active_support/core_ext/object/blank'
require_relative '../support/test_request_host_hash_oracle'

RSpec.describe Woods::Extractors::TestRequestHost, 'returned Hash compositions' do
  programs = TestRequestHostHashOracle.each_program.to_a

  it 'covers all finite ordered operations, selectors, mixed pairs and grouping programs' do
    expect(programs.size).to eq(1984)
    expect(programs.count { |entry| entry.name.start_with?('named /', 'opaque-copy /', 'reverse-plain /') }).to eq(675)
    expect(programs.count { |entry| entry.name.start_with?('selectors /') }).to eq(729)
    expect(programs.count { |entry| entry.name.start_with?('mixed /') }).to eq(540)
  end

  programs.each do |entry|
    it entry.name do
      source = TestRequestHostHashOracle.source_for(entry)
      expect(Prism.parse(source).errors).to eq([]), "invalid fixture: #{source}"
      failures = TestRequestHostHashOracle.violations(entry, described_class)
      expect(failures).to eq([]), "#{source}\n#{failures.join("\n")}"
    end
  end

  # Arbitrary dispatch and blocks retain named witnesses conservatively. These
  # controls do not demand exact results for destructive or opaque operations.
  [
    "attributes_for(:url, subdomain: 'admin').merge(subdomain: 'final') { |key, old, new| old }",
    "attributes_for(:url, subdomain: 'admin').deep_merge(subdomain: 'final') { |key, old, new| old }",
    "attributes_for(:url, subdomain: 'admin').reverse_merge({ locale: 'en' }.customize).except(:subdomain)",
    "attributes_for(:url, subdomain: 'admin').reverse_merge!({ locale: 'en' }.customize).except(:subdomain)",
    "attributes_for(:url, subdomain: 'admin').customize.merge('subdomain' => 'shop').except(:subdomain)",
    "attributes_for(:url, subdomain: 'admin').slice!(:subdomain)",
    "attributes_for(:url, subdomain: 'admin').compact!"
  ].each do |expression|
    it "retains a named witness through opaque dispatch: #{expression}" do
      source = "host! 'shop.example.test'\nroot_url(**#{expression})"

      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to include('admin')
    end
  end

  it 'has independent plain Hash witnesses in which a merge block retains the old host' do
    expect({ subdomain: 'admin' }.merge(subdomain: 'final') { |_key, old, _new| old })
      .to eq(subdomain: 'admin')
    expect({ subdomain: 'admin' }.deep_merge(subdomain: 'final') { |_key, old, _new| old })
      .to eq(subdomain: 'admin')
  end

  describe 'route mapping after an overwrite of a selected string key' do
    include_context 'extractor setup'

    [[], %w[shop api]].each do |controller_hosts|
      context "with controller hosts #{controller_hosts.inspect}" do
        before do
          stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
          redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                  constraints: { subdomain: 'admin' })
          allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
          controllers = controller_hosts.map do |subdomain|
            route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                         constraints: { subdomain: subdomain })
          end
          stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
        end

        %w[merge merge!].each do |merge|
          it "excludes the overwritten admin redirect after #{merge}" do
            copied = "{ **attributes_for(:url, subdomain: 'admin').stringify_keys }"
            # Keep the factory field on the same line: the base suppressed it,
            # while the broken composition reintroduced a false admin hint.
            source = <<~RUBY
              host! 'shop.example.test'
              get url_for(controller: 'settings', action: 'show', **#{copied}.slice('subdomain').#{merge}('subdomain' => 'shop'))
              get '/settings'
            RUBY
            path = create_file('spec/requests/settings_spec.rb', source)
            unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)
            edges = unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }

            aggregate_failures do
              expect(described_class.literal_subdomains(source)).to eq(['shop'])
              expect([nil, ['shop']]).to include(described_class.subdomains(source))
              if controller_hosts.empty?
                expect(edges).to eq([])
                expect(unit.metadata[:routes_ambiguous]).to eq([])
              else
                known = [[{ type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }], []]
                uncertain = [[], [{ request: 'GET /settings',
                                    candidates: ['GET /settings [subdomain=api]', 'GET /settings [subdomain=shop]'] }]]
                expect([known, uncertain]).to include([edges, unit.metadata[:routes_ambiguous]])
              end
            end
          end
        end
      end
    end
  end
end
