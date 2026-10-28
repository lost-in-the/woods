# frozen_string_literal: true

require 'net/http'
require 'stringio'
require 'tmpdir'
require_relative 'build'
require_relative 'serve'
require_relative 'internal/document_checks'
require_relative 'internal/version_checks'
require_relative 'internal/compatibility_checks'
require_relative 'internal/resource_checks'
require_relative 'internal/source_url_checks'
require_relative 'internal/http_checks'

module WoodsDocs
  class Checker
    include DocumentChecks
    include ArtifactChecks
    include GuideChecks
    include VersionChecks
    include CopyChecks
    include CompatibilityChecks
    include ResourceChecks
    include SourceUrlChecks
    include HttpChecks

    def initialize(base)
      @base = WoodsDocs.baseurl(base)
      @directory = WoodsDocs.build_dir(@base)
      @public = File.join(@directory, 'public')
      @metadata = JSON.parse(File.read(File.join(@directory, 'build.json')))
      @documents = {}
      @checks = 0
      @negative_results = []
      @asset_results = []
      @http_results = []
    end

    def run
      raise 'Artifact baseurl does not match' unless @metadata.fetch('baseurl') == @base

      check_public_artifact
      Dir.glob(File.join(@public, '**/*.html')).each { |file| check_document(file) }
      @metadata.fetch('versions').each { |version| check_version(version) }
      check_attribute_traversal
      check_source_urls
      check_network_assets
      check_http
      report = { 'baseurl' => @base, 'assertions' => @checks, 'html_documents' => @documents.size,
                 'negative_fixtures' => @negative_results, 'source_assets' => @asset_results,
                 'public_artifact' => 'passed', 'http' => 'passed', 'http_cases' => @http_results,
                 'browser_acceptance' => 'parent gate' }
      File.write(File.join(@directory, 'checks.json'), "#{JSON.pretty_generate(report)}\n")
      puts "Checked #{@base.empty? ? '/' : "#{@base}/"}: #{@documents.size} HTML documents, #{@checks} assertions, " \
           "#{@negative_results.size} expected broken-link failures; HTTP/search/404 passed"
    end

    private

    def assert(value, message)
      @checks += 1
      raise message unless value
    end

    def document(path)
      @documents[path] ||= WoodsDocs.document(path)
    end

    # All mutations below are confined to a disposable private repository. Owner
    # signing, hooks, refs, objects and inherited Git overrides are not changed.
    def fixture_git(root, *args)
      environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }.merge(
        'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL,
        'GIT_CONFIG_SYSTEM' => File::NULL, 'GIT_NO_LAZY_FETCH' => '1'
      )
      command = ['git', '--no-lazy-fetch', '-C', root,
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                 '-c', 'user.name=Woods docs fixture', '-c', 'user.email=docs-fixture@example.invalid', *args]
      command.unshift('timeout', '--kill-after=5s', '120s') if args.first == 'commit'
      out, error, status = Open3.capture3(environment, *command)
      raise "Private fixture git #{args.first} failed: #{error.strip}" unless status.success?

      out
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { baseurl: '' }
  OptionParser.new { |parser| parser.on('--baseurl PATH') { |value| options[:baseurl] = value } }.parse!
  WoodsDocs.with_lock { WoodsDocs::Checker.new(options.fetch(:baseurl)).run }
end
