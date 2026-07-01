# frozen_string_literal: true

require 'spec_helper'
require 'woods/svelte_flow/source_links'

RSpec.describe Woods::SvelteFlow::SourceLinks do
  describe '.github_blob_url' do
    it 'returns nil without a repo url' do
      expect(described_class.github_blob_url('/srv/app/models/order.rb', repo_url: nil, git_sha: 'abc')).to be_nil
    end

    it 'returns nil without a file path' do
      expect(described_class.github_blob_url(nil, repo_url: 'https://github.com/org/app', git_sha: 'abc')).to be_nil
    end

    it 'pins the blob to the git sha with a repo-relative path' do
      url = described_class.github_blob_url('/srv/app/models/order.rb',
                                            repo_url: 'https://github.com/org/app', git_sha: 'abc123')
      expect(url).to eq('https://github.com/org/app/blob/abc123/app/models/order.rb')
    end

    it 'falls back to HEAD when the sha is missing or unknown' do
      url = described_class.github_blob_url('lib/woods.rb', repo_url: 'https://github.com/org/app/', git_sha: 'unknown')
      expect(url).to eq('https://github.com/org/app/blob/HEAD/lib/woods.rb')
    end
  end

  describe '.repo_relative_path' do
    it 'anchors at a recognized source root' do
      expect(described_class.repo_relative_path('/home/me/proj/app/models/user.rb')).to eq('app/models/user.rb')
    end

    it 'strips a leading slash when no source root matches' do
      expect(described_class.repo_relative_path('/opt/thing.rb')).to eq('opt/thing.rb')
    end
  end
end
