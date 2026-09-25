# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'Maintenance package metadata' do
  { '1.6.4.alpha' => 'release/1.6.4', '1.6.4' => 'v1.6.4' }.each do |version, ref|
    it "links #{version} to its own maintenance source" do
      root = File.expand_path('../..', __dir__)
      script = <<~RUBY
        require 'json'
        require_relative 'lib/woods/version'
        Woods.send(:remove_const, :VERSION)
        Woods.const_set(:VERSION, ARGV.fetch(0))
        puts JSON.generate(Gem::Specification.load('woods.gemspec').metadata)
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, '-e', script, version, chdir: root)
      expect(status.success?).to be(true), error
      metadata = JSON.parse(output)

      expect(metadata.fetch('source_code_uri')).to eq("https://github.com/lost-in-the/woods/tree/#{ref}")
      expect(metadata.fetch('documentation_uri')).to eq("https://github.com/lost-in-the/woods/tree/#{ref}/docs")
      expect(metadata.fetch('changelog_uri')).to eq("https://github.com/lost-in-the/woods/blob/#{ref}/CHANGELOG.md")
    end
  end
end
