# frozen_string_literal: true

module WoodsDocs
  # Shared artifact URL/fragment validation and semantic resource traversal.
  module DocumentChecks
    include ResourceAttributes

    def validate_url(url, from, asset: false)
      path, _query, fragment = WoodsDocs.url_parts(url)
      return if path.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//)}i)

      target = local_target(URI::DEFAULT_PARSER.unescape(path), from, url)
      assert(target == @public || target.start_with?("#{@public}/"), "Link escaped artifact: #{url}")
      target = File.join(target, 'index.html') if File.directory?(target)
      assert(File.file?(target), "Missing rendered target: #{url} in #{from.delete_prefix(@public)}")
      return if ['', '#'].include?(fragment)
      # SVG/media fragments have browser-defined semantics, not HTML anchors.
      return if asset && File.extname(target) != '.html'

      validate_fragment(target, fragment, url, from)
    end

    private

    def local_target(decoded, from, url)
      return from if decoded.empty?
      return File.expand_path(decoded, File.dirname(from)) unless decoded.start_with?('/')

      assert(@base.empty? || decoded == @base || decoded.start_with?("#{@base}/"),
             "Link escaped mount #{@base}: #{url}")
      relative = @base.empty? ? decoded : decoded.delete_prefix(@base)
      File.expand_path(relative.delete_prefix('/'), @public)
    end

    def validate_fragment(target, fragment, url, from)
      assert(File.extname(target) == '.html', "Fragment on non-HTML local target: #{url}")
      name = URI::DEFAULT_PARSER.unescape(fragment.delete_prefix('#'))
      ids = document(target).css('[id], a[name]').flat_map { |node| [node['id'], node['name']] }.compact
      assert(ids.include?(name), "Missing rendered anchor ##{name}: #{url} in #{from.delete_prefix(@public)}")
    end

    def check_document(file)
      doc = document(file)
      doc.css('*').each do |node|
        # Inspect live attributes even inside pre/code; escaped samples contain
        # text nodes. Attribute objects distinguish namespaced SVG xlink:href
        # from href, including both on the same element.
        node.attribute_nodes.each do |attribute|
          name = resource_attribute_name(attribute)
          next unless %w[href src xlink:href].include?(name)

          url = attribute.value
          asset = embedded_asset?(node, name)
          check_network_asset(url, file) if asset || stylesheet?(node)
          validate_url(url, file, asset: asset)
        end
      end
      assert(doc.at_css('main'), "No main landmark: #{file}")
    end

    def check_network_asset(url, file)
      assert(!url.match?(%r{\A(?:https?:|//)}i), "Network asset in #{file}: #{url}")
    end

    def stylesheet?(node)
      node.name == 'link' && node['rel'].to_s.tr('A-Z', 'a-z').split(/[ \t\n\f\r]+/).include?('stylesheet')
    end
  end

  # The locked theme, generated pages and recorded source assets own public files.
  # Source assets use exact recorded paths so guide-linked code can retain names
  # such as cache/, Gemfile or site/internal/ without admitting build output.
  module ArtifactChecks
    THEME_FILES = %w[
      assets/css/just-the-docs-dark.css
      assets/css/just-the-docs-dark.css.map
      assets/css/just-the-docs-default.css
      assets/css/just-the-docs-default.css.map
      assets/css/just-the-docs-head-nav.css
      assets/css/just-the-docs-light.css
      assets/css/just-the-docs-light.css.map
      assets/js/just-the-docs.js
      assets/js/search-data.json
      assets/js/vendor/lunr.min.js
    ].freeze

    private

    def check_public_artifact
      check_style_assets
      allowed = expected_public_paths
      Dir.glob('**/*', File::FNM_DOTMATCH, base: @public).each do |path|
        next if %w[. ..].include?(File.basename(path))

        assert(allowed.include?(path), "Unexpected public artifact: #{path}")
      end
    end

    def check_style_assets
      @metadata.fetch('versions').each do |version|
        STYLE_FILES.each do |path|
          source = File.join(ROOT, 'site', path)
          target = File.join(@public, version.fetch('id'), path)
          assert(File.file?(target) && Digest::SHA256.file(target).hexdigest == Digest::SHA256.file(source).hexdigest,
                 "Staged style asset differs from source: #{target}")
        end
      end
    end

    def expected_public_paths
      expected_public_files.each_with_object(Set.new) do |path, paths|
        until path == '.'
          paths << path
          path = File.dirname(path)
        end
      end
    end

    def expected_public_files
      @metadata.fetch('versions').flat_map do |version|
        files = ['index.html', '404.html', *version.fetch('pages').values, *THEME_FILES, *STYLE_FILES]
        files.concat(version.fetch('source_asset_sha256').keys.map { |path| "source-assets/#{path}" })
        files.map { |path| "#{version.fetch('id')}/#{path}" }
      end.push('index.html', '404.html', 'build.json')
    end
  end
end
