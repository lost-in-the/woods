# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'nokogiri'
require 'open3'
require 'optparse'
require 'pathname'
require 'rake'
require 'set'
require 'uri'
require 'yaml'
require 'jekyll'
require_relative 'internal/links'
require_relative 'internal/pages'

# All generated sources, caches, metadata and output stay in ignored tmp/.
module WoodsDocs
  ROOT = File.expand_path('..', __dir__)
  WORK = File.join(ROOT, 'tmp/woods-docs')
  LOCK = ENV.fetch('WOODS_DOCS_LOCK', File.join(File.dirname(ROOT), '.heavy.lock'))
  MANIFEST = YAML.safe_load_file(File.join(__dir__, 'manifest.yml'))

  def self.with_lock
    File.open(LOCK, File::RDWR | File::CREAT, 0o644) do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        warn "Heavy resource lock is held: #{LOCK}; no work started. Retry after its owner finishes."
        exit 75
      end
      yield
    end
  end

  def self.baseurl(value)
    return '' if ['', '/'].include?(value)
    raise ArgumentError, 'baseurl must be empty or a path such as /woods (no trailing slash)' unless
      value.match?(%r{\A(?:/[A-Za-z0-9_-]+)+\z})

    value
  end

  def self.build_dir(base)
    File.join(WORK, base.empty? ? 'root' : base.delete_prefix('/').tr('/', '_'))
  end

  def self.document(path)
    Nokogiri::HTML5(File.read(path))
  end

  def self.url_parts(url)
    url.match(/\A([^?#]*)(\?[^#]*)?(\#.*)?\z/).captures.map { |part| part || '' }
  end

  # Every Git read is local. In a partial clone even cat-file/show must not fetch.
  class Repository
    attr_reader :sha, :working

    def self.git(*args, root: ROOT)
      out, err, status = Open3.capture3(
        { 'GIT_NO_LAZY_FETCH' => '1', 'GIT_OPTIONAL_LOCKS' => '0' }, 'git', '--no-lazy-fetch', '-C', root, *args
      )
      raise "Local git #{args.first} failed (no implicit fetch): #{err.strip}" unless status.success?

      out
    end

    def initialize(sha, working: false, root: ROOT)
      @sha = sha
      @working = working
      @root = File.realpath(root)
      @files = self.class.git('ls-tree', '-r', '-z', '--name-only', sha, root: @root).split("\0").to_set
      @directories = Set.new(['.'])
      @files.each do |file|
        dir = File.dirname(file)
        until @directories.include?(dir)
          @directories << dir
          dir = File.dirname(dir)
        end
      end
    end

    def kind(path, committed: false)
      return working_kind(path) if working && !committed
      return 'blob' if @files.include?(path)
      return 'tree' if @directories.include?(path)

      nil
    end

    def read(path, committed: false)
      working && !committed ? File.read(File.join(@root, path)) : self.class.git('show', "#{sha}:#{path}", root: @root)
    end

    private

    def working_kind(path)
      full = File.join(@root, path)
      return nil unless File.exist?(full)

      real = File.realpath(full)
      return nil unless real == @root || real.start_with?("#{@root}/")
      return 'tree' if File.directory?(full)
      return 'blob' if File.file?(full)

      nil
    end
  end

  class Builder
    attr_reader :base, :directory

    def initialize(base)
      @base = WoodsDocs.baseurl(base)
      @directory = WoodsDocs.build_dir(@base)
    end

    def run
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      load_versions
      @versions.each { |version| load_guides(version) }
      render_versions
      metadata = build_metadata(started)
      File.write(File.join(directory, 'build.json'), "#{JSON.pretty_generate(metadata)}\n")
      FileUtils.cp(File.join(directory, 'build.json'), File.join(directory, 'public/build.json'))
      puts "Built #{base.empty? ? '/' : "#{base}/"}: #{metadata.fetch('seconds')}s → #{directory}/public"
    end

    private

    def render_versions
      FileUtils.rm_rf(directory)
      FileUtils.mkdir_p(File.join(directory, 'public'))
      content = PageContent.new(@versions)
      @versions.each { |version| PageRenderer.new(version, directory, content, @status).render }
      content.write_hub(directory)
    end

    def load_versions
      head = Repository.git('rev-parse', 'HEAD').strip
      pin = MANIFEST.fetch('release')
      actual = Repository.git('rev-parse', '--verify', "refs/tags/#{pin.fetch('name')}^{commit}").strip
      raise "Release tag mismatch: expected #{pin.fetch('commit')}, got #{actual}" unless actual == pin.fetch('commit')

      @status = Repository.git('status', '--porcelain=v1', '--untracked-files=all').lines.map(&:chomp)
      @versions = [
        { 'id' => 'unreleased', 'label' => 'Unreleased checkout', 'repo' => Repository.new(head, working: true) },
        { 'id' => pin.fetch('name'), 'label' => pin.fetch('name'), 'repo' => Repository.new(actual) }
      ]
    end

    def build_metadata(started)
      {
        'baseurl' => base, 'ruby' => RUBY_DESCRIPTION, 'bundler' => Bundler::VERSION,
        'lock_sha256' => Digest::SHA256.file(File.join(__dir__, 'Gemfile.lock')).hexdigest,
        'checkout_status' => @status,
        'versions' => @versions.map { |version| version.except('repo', 'bodies') },
        'seconds' => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      }
    end

    def load_guides(version)
      paths = MANIFEST.fetch('groups').values.flatten
      raise 'Guide basenames must be unique' unless paths.map { |path| File.basename(path) }.uniq.size == paths.size

      repo = version.fetch('repo')
      missing = paths.reject { |path| repo.kind(path) == 'blob' }
      raise "Missing checkout guides: #{missing.join(', ')}" if repo.working && !missing.empty?

      bodies = (paths - missing).to_h { |path| [path, repo.read(path)] }
      version['missing_guides'] = missing
      record_guides(version, bodies)
    end

    def record_guides(version, bodies)
      version['sha'] = version.fetch('repo').sha
      version['prefix'] = "#{base}/#{version.fetch('id')}"
      version['pages'] = bodies.to_h { |path, _| [path, "#{File.basename(path, '.md')}.html"] }
      version['guide_sha256'] = bodies.transform_values { |body| Digest::SHA256.hexdigest(body) }
      version['content_sha256'] = Digest::SHA256.hexdigest(bodies.sort.flatten.join("\0"))
      version['bodies'] = bodies
      version['pages']['site/fixtures/compatibility.md'] = 'compatibility.html'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { baseurl: '' }
  OptionParser.new { |parser| parser.on('--baseurl PATH') { |value| options[:baseurl] = value } }.parse!
  WoodsDocs.with_lock { WoodsDocs::Builder.new(options.fetch(:baseurl)).run }
end
