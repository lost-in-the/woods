# frozen_string_literal: true

module WoodsDocs
  # Exact local styling payload, shared by staging and the public artifact boundary.
  STYLE_FILES = %w[
    assets/woods-docs/woods-docs.css
    assets/woods-docs/scroll-regions.js
    assets/woods-docs/LICENSE.txt
    assets/woods-docs/fonts/README.txt
    assets/woods-docs/fonts/inter/inter-latin-400-normal.woff2
    assets/woods-docs/fonts/inter/inter-latin-500-normal.woff2
    assets/woods-docs/fonts/inter/inter-latin-700-normal.woff2
    assets/woods-docs/fonts/inter/inter-latin-ext-400-normal.woff2
    assets/woods-docs/fonts/inter/inter-latin-ext-500-normal.woff2
    assets/woods-docs/fonts/inter/inter-latin-ext-700-normal.woff2
    assets/woods-docs/fonts/inter/OFL.txt
    assets/woods-docs/fonts/fira-code/FiraCode-Bold.woff2
    assets/woods-docs/fonts/fira-code/FiraCode-Medium.woff2
    assets/woods-docs/fonts/fira-code/FiraCode-Regular.woff2
    assets/woods-docs/fonts/fira-code/OFL.txt
  ].freeze

  # Generated navigation and landing text; canonical guide bodies stay separate.
  class PageContent
    def initialize(versions)
      @versions = versions
    end

    def version_links(current, output)
      @versions.map do |version|
        available = output == 'index.html' || version.fetch('pages').value?(output)
        path = available && output != 'index.html' ? output : ''
        { 'label' => version.fetch('label'), 'url' => "#{version.fetch('prefix')}/#{path}",
          'current' => current.equal?(version), 'fallback' => !available }
      end
    end

    def title(body)
      body.lines.find { |line| line.start_with?('# ') }.to_s.delete_prefix('# ').strip
    end

    def landing(version)
      lines = ["# Choose a task\n",
               "These guides describe **#{version.fetch('label')}**. Version availability is not a support policy.\n",
               'Switching versions keeps the guide when that version includes it. Otherwise you arrive here ' \
               'because that guide is unavailable; choose a task or search this version.']
      MANIFEST.fetch('groups').each do |group, paths|
        lines << "\n## #{group}\n"
        paths.each do |path|
          next unless version.fetch('bodies').key?(path)

          label = title(version.fetch('bodies').fetch(path))
          lines << "- [#{label}](#{version.fetch('prefix')}/#{version.fetch('pages').fetch(path)})"
        end
      end
      append_missing_guides(lines, version.fetch('missing_guides'))
      "#{lines.join("\n")}\n"
    end

    def write_hub(directory)
      public_root = File.join(directory, 'public')
      index = hub_html('Woods guides', 'Choose the documentation matching your checkout or gem.')
      missing = hub_html(
        'Page not found',
        'This URL is not included. Choose a documentation version, then use its guide list or search.'
      )
      File.write(File.join(public_root, 'index.html'), index)
      File.write(File.join(public_root, '404.html'), missing)
    end

    private

    def append_missing_guides(lines, missing)
      return if missing.empty?

      lines << "\n## Guides absent from this release\n"
      lines << 'These checkout guides did not exist at the pinned release. This is expected; ' \
               'their unreleased content is not substituted into this version.'
      missing.each { |path| lines << "- `#{path}`" }
    end

    def hub_html(heading, text)
      stylesheet = "#{@versions.first.fetch('prefix')}/assets/woods-docs/woods-docs.css"
      links = @versions.map do |version|
        "<li><a href=\"#{version.fetch('prefix')}/\">#{version.fetch('label')}</a></li>"
      end.join
      '<!doctype html><html lang="en"><head><meta charset="utf-8">' \
        '<meta name="viewport" content="width=device-width, initial-scale=1">' \
        "<title>#{heading} — Woods</title><meta name=\"color-scheme\" content=\"light dark\">" \
        "<link rel=\"stylesheet\" href=\"#{stylesheet}\"></head><body class=\"woods-hub\"><main>" \
        "<h1>#{heading}</h1><p>#{text}</p><ul>#{links}</ul>" \
        "<p>Local / CI artifact candidate. Version availability is not a support policy.</p></main></body></html>\n"
    end
  end

  # Stage and render one isolated version, then rewrite only rendered resources.
  class PageRenderer
    def initialize(version, directory, content, status)
      @version = version
      @directory = directory
      @content = content
      @status = status
      @source = File.join(directory, 'source', version.fetch('id'))
      @destination = File.join(directory, 'public', version.fetch('id'))
    end

    def render
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      FileUtils.mkdir_p(@source)
      FileUtils.cp_r(File.join(ROOT, 'site/_includes'), @source)
      stage_style
      stage_guides
      stage_navigation
      initialize_search
      Jekyll::Site.new(configuration).process
      rewrite_links
      @version['build_seconds'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(3)
    end

    private

    def stage_style
      STYLE_FILES.each do |path|
        destination = File.join(@source, path)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(ROOT, 'site', path), destination)
      end
    end

    def stage_page(filename, data, body)
      File.write(File.join(@source, filename), "#{YAML.dump(data)}---\n#{body}")
    end

    def stage_guides
      @version.fetch('bodies').each_with_index do |(path, body), index|
        output = @version.fetch('pages').fetch(path)
        data = { 'layout' => 'default', 'title' => @content.title(body), 'permalink' => "/#{output}",
                 'nav_order' => index + 1, 'render_with_liquid' => false, 'has_toc' => false,
                 'version_links' => @content.version_links(@version, output) }
        stage_page(File.basename(path), data, body)
      end
    end

    def stage_navigation
      fixture_data = { 'layout' => 'default', 'title' => 'Compatibility fixture', 'permalink' => '/compatibility.html',
                       'render_with_liquid' => false, 'nav_exclude' => true, 'search_exclude' => true,
                       'version_links' => @content.version_links(@version, 'compatibility.html') }
      stage_page('compatibility.md', fixture_data, File.read(File.join(ROOT, 'site/fixtures/compatibility.md')))
      landing_data = { 'layout' => 'default', 'title' => 'Choose a task', 'permalink' => '/', 'nav_order' => 0,
                       'version_links' => @content.version_links(@version, 'index.html') }
      stage_page('index.md', landing_data, @content.landing(@version))
      not_found = File.read(File.join(ROOT, 'site/404.html'))
      data = { 'version_links' => @content.version_links(@version, '404.html') }
      File.write(File.join(@source, '404.html'), not_found.sub("---\n", "#{YAML.dump(data).delete_suffix("\n")}\n"))
    end

    def initialize_search
      # Publish via the locked theme's own task in staging, with Liquid enabled.
      Rake.application = Rake::Application.new
      load File.join(Gem.loaded_specs.fetch('just-the-docs').full_gem_path, 'lib/tasks/search.rake')
      Dir.chdir(@source) { Rake::Task['search:init'].invoke }
    end

    def provenance
      return "Exact release pin #{@version.fetch('sha')}" unless @version.fetch('repo').working

      status = @status.empty? ? 'clean checkout' : 'dirty checkout — includes uncommitted working-tree text'
      "HEAD #{@version.fetch('sha')}; #{status}; guide SHA-256 #{@version.fetch('content_sha256')[0, 12]}"
    end

    def configuration
      # Jekyll resolves caches beneath source; keep each version's cache hidden.
      Jekyll.configuration(
        'config' => File.join(ROOT, 'site/_config.yml'), 'source' => @source, 'destination' => @destination,
        'baseurl' => @version.fetch('prefix'), 'cache_dir' => '.jekyll-cache',
        'docs_version' => @version.fetch('id'), 'docs_label' => @version.fetch('label'),
        'docs_provenance' => provenance, 'quiet' => true
      )
    end

    def rewrite_links
      links = Links.new(@version.fetch('repo'), @version.fetch('pages'), @version.fetch('prefix'),
                        asset_directory: @destination)
      @version.fetch('pages').each do |original, output|
        path = File.join(@destination, output)
        doc = links.rewrite_document(WoodsDocs.document(path), original)
        File.write(path, doc.to_html)
      end
      @version['source_asset_sha256'] = links.source_asset_sha256
    end
  end
end
