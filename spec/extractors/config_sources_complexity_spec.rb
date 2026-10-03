# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'tmpdir'
require 'woods'
require 'woods/extractors/config_file_extractor'
require 'woods/extractors/config_read_scanner'
require 'woods/extractors/route_extractor'
require 'woods/extractors/configuration_extractor'
require 'woods/extractors/config_source_guard'

# YAML files and the Ruby that reads them are uncontrolled input. Every
# pattern the config-file extractor and the config-read scanner apply must
# stay linear on adversarial text. Ruby 3.2+ memoizes regexp backtracking,
# which hides most polynomial patterns; the Ruby 3.0/3.1 rows catch a
# regression through the Timeout fallback.
RSpec.describe 'Config source scan complexity' do
  include_context 'extractor setup'

  budget_seconds = 1.0
  spaces = ' ' * 50_000
  word = 'a' * 50_000

  before do
    configuration = double('Configuration',
                           config_file_paths: Woods::Extractors::ConfigFileExtractor::DEFAULT_PATHS,
                           config_file_values: true,
                           settings_readers: [{ constant: 'Settings', file: 'config/settings.yml' }])
    allow(Woods).to receive(:configuration).and_return(configuration)
  end

  around do |example|
    if Regexp.respond_to?(:timeout=)
      previous = Regexp.timeout
      Regexp.timeout = budget_seconds
      begin
        example.run
      ensure
        Regexp.timeout = previous
      end
    else
      Timeout.timeout(budget_seconds * 5) { example.run }
    end
  end

  def within_budget(budget)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < budget
  end

  {
    'unterminated ERB openers' => '<%' * 50_000,
    'repeated ERB output tags' => "a: #{'<%= x %>' * 10_000}\n",
    'ERB closers with no opener' => '%>' * 50_000,
    'repeated ENV openers' => "a: <%= #{'ENV[' * 10_000} %>\n",
    'an ENV opener then spaces' => "a: <%= ENV[#{spaces} %>\n",
    'repeated ENV.fetch near-matches' => "a: <%= #{'ENV.fetch("' * 10_000} %>\n",
    'a long key with no colon' => "#{word}\n",
    'a long key on an unparsable document' => "#{word}: [\n",
    'many unparsable key lines' => "k.-k: [\n" * 10_000,
    'a value of repeated URL userinfo near-matches' => "a: \"x://#{'a:' * 2_000}\"\n",
    'a value of repeated scheme separators' => "a: \"#{'://' * 1_300}\"\n",
    'a long opaque value' => "a: #{'a1' * 2_000}\n",
    'a value of short opaque runs' => "a: \"#{'a1b2c3d4e5f6g7h8i9 ' * 200}\"\n",
    'a long whitespace value' => "a: \"#{spaces}\"\n",
    'deeply nested flow sequences' => "a: #{'[' * 5_000}#{']' * 5_000}\n",
    'deeply nested mappings' => "#{(0...2_000).map { |n| "#{' ' * n}k:\n" }.join}#{' ' * 2_000}v: 1\n",
    'many anchors and aliases' => "#{(0...10_000).map { |n| "k#{n}: &a#{n} 1\n" }.join}z: *a0\n",
    'many merge keys of one anchor' => "base: &base\n  a: 1\n#{"k:\n  <<: *base\n" * 10_000}"
  }.each do |label, yaml|
    it "the config file extractor stays within #{budget_seconds}s on #{label}" do
      path = create_file('config/settings.yml', yaml)
      extractor = Woods::Extractors::ConfigFileExtractor.new

      within_budget(budget_seconds) { expect(extractor.extract_config_file(path)).not_to be_nil }
    end
  end

  {
    'a routing call then spaces' => "get#{spaces}",
    'a routing call, spaces, a paren, spaces' => "get#{spaces}(#{spaces}",
    'repeated routing calls on one line' => 'get ' * 10_000,
    'a routing call with a long unterminated string' => "get \"#{word}",
    'a routing call with a long symbol then a near-miss' => "resources :#{word}!",
    'leading spaces then no call' => "#{spaces}x",
    'many declaration lines' => "resources :widgets\n" * 10_000,
    'a long alternation near-miss' => "#{'resource' * 6_000}\n"
  }.each do |label, source|
    it "the route declaration scan stays within #{budget_seconds}s on #{label}" do
      extractor = Woods::Extractors::RouteExtractor.new

      within_budget(budget_seconds) { extractor.send(:route_declarations, source) }
    end
  end

  {
    'gem then spaces' => "gem#{spaces}",
    'gem, spaces, a paren, spaces' => "gem#{spaces}(#{spaces}",
    'many blank lines' => "\n" * 50_000,
    'many indented near-miss lines' => "   gemx\n" * 10_000,
    'repeated gem openers on one line' => 'gem(' * 10_000,
    'a gem with a long unterminated name' => "gem '#{word}"
  }.each do |label, source|
    it "the Gemfile declaration scan stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) { source.scan(Woods::Extractors::ConfigurationExtractor::GEM_DECLARATION) }
    end
  end

  {
    'repeated scheme separators' => '://' * 16_000,
    'a scheme separator then repeated colons' => "://#{'a:' * 25_000}",
    'a scheme separator, a long user, no password' => "://#{word}@",
    'repeated userinfo near-matches' => '://a:b ' * 7_000,
    'repeated private key headers' => "-----BEGIN PRIVATE KEY-----\n" * 5_000,
    'a private key header then a long body' => "-----BEGIN PRIVATE KEY-----\n#{"#{'a' * 60}\n" * 5_000}",
    'repeated token prefixes' => 'eyJ' * 16_000,
    'repeated dotted token near-matches' => 'eyJa.eyJa ' * 5_000,
    'repeated database URL openers' => 'postgres://a:' * 4_000,
    'repeated key prefixes' => 'sk_live_' * 6_000,
    'a long word' => word
  }.each do |label, source|
    it "source redaction stays within #{budget_seconds}s on #{label}" do
      within_budget(budget_seconds) { Woods::Extractors::ConfigSourceGuard.redact(source) }
    end
  end

  {
    'a location of repeated colons' => ':' * 50_000,
    'a location with a long digit run' => "config/routes.rb:#{'1' * 50_000}",
    'a location with a long digit run then a letter' => "config/routes.rb:#{'1' * 50_000}x"
  }.each do |label, location|
    it "the route location parse stays within #{budget_seconds}s on #{label}" do
      extractor = Woods::Extractors::RouteExtractor.new
      route = double('Route', source_location: location)

      within_budget(budget_seconds) { extractor.send(:route_location, route) }
    end
  end

  {
    'config_for then spaces' => "config_for#{spaces}",
    'config_for, spaces, a paren, spaces' => "config_for#{spaces}(#{spaces}",
    'repeated config_for openers' => 'config_for(' * 10_000,
    'config_for with a long unterminated string' => "config_for(\"#{word}",
    'config_for with a long symbol then a near-miss' => "config_for(:#{word}!",
    'repeated near-match config_for calls' => 'config_for("a" ' * 10_000,
    'YAML then spaces' => "YAML#{spaces}",
    'YAML, a dot, spaces' => "YAML.#{spaces}load_file#{spaces}",
    'repeated load_file openers' => 'YAML.load_file(' * 10_000,
    'repeated Rails.root.join openers' => 'YAML.load_file(Rails.root.join(' * 5_000,
    'load_file with a long unterminated string' => "YAML.load_file(\"#{word}",
    'a join with many literal segments' => "YAML.load_file(Rails.root.join(#{'"a", ' * 10_000}",
    'a join then spaces' => "YAML.load_file(Rails.root.join(\"a\"#{spaces}",
    'Rails then spaces' => "YAML.load_file(Rails#{spaces}",
    'repeated settings constants' => 'Settings ' * 10_000,
    'a settings constant then spaces' => "Settings#{spaces}",
    'repeated namespaced settings constants' => 'A::Settings.' * 10_000,
    'a long chain of colons before the constant' => "#{':' * 50_000}Settings.x"
  }.each do |label, source|
    it "the config read scanner stays within #{budget_seconds}s on #{label}" do
      scanner = Class.new { include Woods::Extractors::ConfigReadScanner }.new

      within_budget(budget_seconds) { scanner.scan_config_dependencies(source) }
    end
  end
end
