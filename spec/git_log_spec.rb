# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'open3'
require 'woods/git_log'

RSpec.describe Woods::GitLog do
  around do |example|
    Dir.mktmpdir('woods_git_log') do |dir|
      @root = dir
      example.run
    end
  end

  def git(*args)
    output, status = Open3.capture2e('git', '-C', @root, *args)
    raise output unless status.success?
  end

  before do
    git('init', '-q')
    File.write(File.join(@root, 'a.rb'), "class A; end\n")
    git('add', '-A')
    git('-c', 'user.name=Woods test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
        'commit', '-qm', 'Add a')
  end

  let(:log) { described_class.new(root: @root) }

  it "names git's own first stderr line when the history walk fails" do
    expect { log.stream(format: '%x00%H%x00', since: '1970-01-01', revision: 'no-such-revision', &:read) }
      .to raise_error(described_class::ReadError, /\Ahistory command exited 128: fatal: \S/)
  end

  it "names git's own first stderr line when a walk over named commits fails" do
    expect { log.patch_stream(['f' * 40], &:read) }
      .to raise_error(described_class::ReadError, /\Apatch command exited 128: fatal: \S/)
  end

  it 'keeps the message to one line of bounded length' do
    expect { log.renames(['e' * 40]) }.to raise_error(described_class::ReadError) do |error|
      expect(error.message).not_to include("\n")
      expect(error.message.length).to be <= 300
    end
  end
end
