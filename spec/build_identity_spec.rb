# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'woods/build_identity'

RSpec.describe Woods::BuildIdentity do
  around do |example|
    Dir.mktmpdir('woods-build-identity') do |directory|
      @base = File.realpath(directory)
      example.run
    end
  end

  def git(dir, *args)
    _out, errors, status = Open3.capture3('git', '-C', dir, *args)
    raise errors unless status.success?
  end

  def repository(path)
    FileUtils.mkdir_p(File.join(path, 'lib'))
    File.write(File.join(path, 'lib', 'woods.rb'), "# gem\n")
    git(path, 'init', '-q')
    git(path, 'add', '.')
    git(path, '-c', 'user.name=Spec', '-c', 'user.email=spec@example.invalid', 'commit', '-qm', 'init')
    out, = Open3.capture3('git', '-C', path, 'rev-parse', 'HEAD')
    out.strip
  end

  it 'records the revision and dirty flag of a checkout rooted at the gem root' do
    gem_root = File.join(@base, 'gem-checkout')
    head = repository(gem_root)

    clean = described_class.new(spec: nil, root: gem_root)
    expect(clean.manifest_fields).to eq(woods_revision: head, woods_revision_dirty: false)

    File.write(File.join(gem_root, 'lib', 'woods.rb'), "# edited\n")
    expect(described_class.new(spec: nil, root: gem_root).dirty).to be(true)
  end

  it "never reports the enclosing application's revision for a gem vendored inside it" do
    application = File.join(@base, 'application')
    repository(application)
    vendored = File.join(application, 'vendor', 'bundle', 'gems', 'woods-1.0.0')
    FileUtils.mkdir_p(vendored)

    expect(described_class.new(spec: nil, root: vendored).manifest_fields)
      .to eq(woods_revision: nil, woods_revision_dirty: nil)
  end

  it 'uses the locked revision of a Bundler git source' do
    skip 'Bundler git sources are unavailable' unless defined?(Bundler::Source::Git)

    revision = 'd' * 40
    source = Bundler::Source::Git.allocate
    source.instance_variable_set(:@options, { 'revision' => revision })
    spec = double('spec', source: source)

    expect(described_class.new(spec: spec, root: File.join(@base, 'installed')).manifest_fields)
      .to eq(woods_revision: revision, woods_revision_dirty: false)
  end

  it 'records no revision for a released gem and runs no git' do
    expect(Open3).not_to receive(:capture3)

    identity = described_class.new(spec: nil, root: File.join(@base, 'released'))

    expect(identity.revision).to be_nil
    expect(identity.dirty).to be_nil
    expect(identity.version).to eq(Woods::VERSION)
  end

  describe '.compare' do
    let(:reader) { instance_double(described_class, version: '2.2.0', revision: 'b' * 40, dirty: false) }

    it 'reports unknown without a writer version' do
      expect(described_class.compare({}, reader: reader).state).to eq('unknown')
    end

    it 'ignores a malformed writer revision' do
      comparison = described_class.compare({ 'woods_version' => '2.2.0', 'woods_revision' => 'not-a-sha' },
                                           reader: reader)

      expect(comparison.state).to eq('same_version')
    end

    it 'reports the same build for matching revisions' do
      comparison = described_class.compare({ 'woods_version' => '2.2.0', 'woods_revision' => 'b' * 40 },
                                           reader: reader)

      expect(comparison.state).to eq('same_build')
      expect(comparison).not_to be_mismatch
    end
  end
end
