# frozen_string_literal: true

require 'spec_helper'
require 'woods/git_version'

RSpec.describe Woods::GitVersion do
  before { described_class.reset_announcements! }
  after { described_class.reset_announcements! }

  describe '.parse' do
    {
      "git version 2.30.2\n" => '2.30.2',
      'git version 2.31.0' => '2.31.0',
      'git version 2.39.3 (Apple Git-145)' => '2.39.3',
      'git version 2.45.1.windows.1' => '2.45.1',
      'git version 2.31.0.rc1' => '2.31.0',
      'git version 3.0' => '3.0.0'
    }.each do |answer, version|
      it "reads #{answer.strip.inspect} as #{version}" do
        expect(described_class.parse(answer)).to eq(Gem::Version.new(version))
      end
    end

    ['', nil, 'git: command not found', 'version 2.30.2', 'git version unknown', "\xFF\xFE".b].each do |answer|
      it "counts #{answer.inspect} as unknown" do
        expect(described_class.parse(answer)).to be_nil
      end
    end
  end

  describe '.too_old?' do
    it 'holds only for a known version before 2.31' do
      expect(described_class.too_old?(Gem::Version.new('2.30.9'))).to be(true)
      expect(described_class.too_old?(Gem::Version.new('2.31.0'))).to be(false)
      expect(described_class.too_old?(Gem::Version.new('2.39.3'))).to be(false)
      expect(described_class.too_old?(nil)).to be(false)
    end
  end

  describe '.announce' do
    let(:logger) { instance_double(Logger, warn: nil) }
    let(:line) do
      '[Woods] Git 2.30.2 is older than 2.31, which git enrichment and git_commits.json need; ' \
        'extraction continues without them.'
    end

    it 'prints the version found and the version needed on stderr, and logs it' do
      expect { described_class.announce(Gem::Version.new('2.30.2'), logger: logger) }
        .to output("#{line}\n").to_stderr
      expect(logger).to have_received(:warn).with(line)
    end

    it 'prints once per process however many runs announce it, and still logs every run' do
      expect do
        3.times { described_class.announce(Gem::Version.new('2.30.2'), logger: logger) }
      end.to output("#{line}\n").to_stderr
      expect(logger).to have_received(:warn).with(line).exactly(3).times
    end
  end
end
