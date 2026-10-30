# frozen_string_literal: true

require 'spec_helper'
require 'rbconfig'
require 'woods/extractors/source_origin'

# Stable, machine-independent source labels and origins (LOS-127, LOS-128).
RSpec.describe Woods::Extractors::SourceOrigin do
  let(:root) { '/srv/host/checkout' }

  def site(path)
    described_class.site(path, root: root)
  end

  it 'labels an application file relative to the root' do
    expect(site('/srv/host/checkout/app/models/post.rb').to_h)
      .to eq(origin: 'app', location: 'app/models/post.rb')
  end

  it 'labels a concern under the root as the application' do
    expect(site('/srv/host/checkout/app/models/concerns/taggable.rb').origin).to eq('app')
  end

  it 'names an installed gem by its directory, wherever the bundle lives' do
    path = '/srv/host/checkout/vendor/bundle/ruby/3.3.0/gems/activerecord-7.1.6/' \
           'lib/active_record/associations/builder/association.rb'

    expect(site(path).to_h).to eq(
      origin: 'framework',
      location: 'activerecord-7.1.6/lib/active_record/associations/builder/association.rb'
    )
  end

  it 'classifies every Rails gem as the framework and any other gem as a gem' do
    described_class::RAILS_GEMS.each do |name|
      expect(site("/gems/ruby/3.3.0/gems/#{name}-7.1.6/lib/x.rb").origin).to eq('framework')
    end
    expect(site('/gems/ruby/3.3.0/gems/devise-4.9.4/lib/devise/models.rb').to_h)
      .to eq(origin: 'gem', location: 'devise-4.9.4/lib/devise/models.rb')
  end

  it 'keeps a platform suffix in the label and out of the gem name' do
    expect(site('/g/gems/nokogiri-1.16.0-x86_64-linux/lib/nokogiri.rb').to_h)
      .to eq(origin: 'gem', location: 'nokogiri-1.16.0-x86_64-linux/lib/nokogiri.rb')
    expect(site('/g/gems/rack-test-2.1.0/lib/rack/test.rb').origin).to eq('gem')
  end

  it 'names a Bundler git checkout by its directory' do
    expect(site('/g/bundler/gems/rails-1a2b3c4d5e6f/activerecord/lib/active_record/base.rb').to_h)
      .to eq(origin: 'framework', location: 'rails-1a2b3c4d5e6f/activerecord/lib/active_record/base.rb')
    expect(site('/g/bundler/gems/pundit-0123abcdef01/lib/pundit.rb').origin).to eq('gem')
  end

  it 'names a path gem outside the root by its loaded spec' do
    spec = Gem.loaded_specs.values.min_by(&:name)
    path = File.join(spec.full_gem_path, 'lib', 'entry.rb')

    expect(site(path).location).to eq("#{spec.full_name}/lib/entry.rb")
  end

  it 'labels the Ruby standard library under ruby/' do
    expect(site(File.join(RbConfig::CONFIG['rubylibdir'], 'forwardable.rb')).to_h)
      .to eq(origin: 'gem', location: 'ruby/forwardable.rb')
  end

  it 'never publishes an absolute path: an unclaimed file keeps only its basename' do
    expect(site('/home/dev/elsewhere/callbacks.rb').to_h)
      .to eq(origin: 'unknown', location: 'external/callbacks.rb')
  end

  it 'is unknown without a path, and keeps a non-path location as it is' do
    expect(site(nil).to_h).to eq(origin: 'unknown', location: nil)
    expect(site('(eval)').to_h).to eq(origin: 'unknown', location: '(eval)')
  end

  it 'does not take a vendored file or a bundle under the root for the application' do
    expect(site('/srv/host/checkout/vendor/gems/legacy/lib/legacy.rb').to_h)
      .to eq(origin: 'gem', location: 'legacy/lib/legacy.rb')
    expect(site('/srv/host/checkout/vendor/patches/legacy.rb').origin).to eq('unknown')
    expect(site('/srv/host/checkout/node_modules/x/index.rb').origin).to eq('unknown')
  end

  it 'does not take a similar root prefix for the root' do
    expect(site('/srv/host/checkout-old/app/models/post.rb').origin).to eq('unknown')
  end

  it 'reads the root from Rails when none is given' do
    stub_const('Rails', double('Rails', root: Pathname.new('/app')))

    expect(described_class.location('/app/app/models/post.rb')).to eq('app/models/post.rb')
    expect(described_class.origin('/app/app/models/post.rb')).to eq('app')
  end

  it 'has no application without Rails' do
    hide_const('Rails')

    expect(described_class.site('/app/app/models/post.rb').origin).to eq('unknown')
  end
end
