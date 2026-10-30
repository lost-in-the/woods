# frozen_string_literal: true

module WoodsDocs
  # Direct SVG image URLs use the same staged, offline policy as HTML img src.
  module SvgChecks
    private

    def svg_network_asset_fixtures
      pinned = 'https://raw.githubusercontent.com/lost-in-the/woods/' \
               "#{MANIFEST.fetch('release').fetch('commit')}/assets/woods-mark-black.svg"
      urls = { 'external' => 'https://example.com/image.svg', 'pinned' => pinned }
      urls.each_with_object({}) do |(id, url), fixtures|
        %w[image feImage].each do |element|
          { 'href' => "href=\"#{url}\"", 'xlink-href' => "xlink:href=\"#{url}\"",
            'both-href' => "href=\"#{url}\" xlink:href=\"data:image/png;base64,AA==\"",
            'both-xlink' => "href=\"data:image/png;base64,AA==\" xlink:href=\"#{url}\"" }.each do |name, attributes|
            fixtures["svg-#{element}-#{name}-#{id}"] = "<svg><#{element} #{attributes}></#{element}></svg>"
          end
        end
      end
    end

    def check_svg_fixture_assets(doc, version)
      %w[svg-image-asset svg-filter-asset pre-svg-image-asset pre-svg-filter-asset
         code-svg-image-asset code-svg-filter-asset].each do |id|
        node = doc.at_css("##{id}")
        assert(node&.namespace&.href == 'http://www.w3.org/2000/svg', "SVG image element was lost: #{id}")
        %w[href xlink:href].each { |name| check_svg_fixture_attribute(node, name, id, version) }
      end
      assert(doc.at_css('pre #pre-svg-image-asset') && doc.at_css('code #code-svg-image-asset'),
             'Live SVG resource formatting wrappers were lost')
    end

    def check_svg_fixture_attribute(node, name, id, version)
      attribute = node.attribute_nodes.find { |candidate| resource_attribute_name(candidate) == name }
      expected = "#{version.fetch('prefix')}/source-assets/assets/woods-mark-black.svg" \
                 "?fixture=#{id}&attribute=#{name}#svgView(viewBox(0,0,120,120))"
      assert(attribute&.value == expected, "SVG source asset was not staged: #{id}/#{name}")
      if name == 'xlink:href'
        assert(attribute.namespace&.href == 'http://www.w3.org/1999/xlink', "SVG xlink namespace was lost: #{id}")
      end
      @asset_results << { 'fixture' => 'svg-image', 'version' => version.fetch('id'),
                          'element' => node.name, 'attribute' => name, 'url' => attribute.value }
    end
  end

  # Live HTML/SVG attributes and forbidden network resources, including wrappers.
  module ResourceChecks
    include SvgChecks

    private

    def attribute_fixtures
      data = 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%2F%3E'
      {
        'main' => 'Ordinary content',
        'href' => '<a href="#target">Local anchor</a>',
        'external-href' => '<a href="https://example.com/image.svg">External navigation</a>',
        'src' => '<img src="fixture.svg" alt="Local fixture">',
        'svg-data-image' => "<svg><image href=\"#{data}\" xlink:href=\"#{data}\"></image></svg>",
        'svg-data-filter' => "<svg><filter><feImage href=\"#{data}\" xlink:href=\"#{data}\"></feImage></filter></svg>",
        'svg-hrefs' => '<svg><use href="#target" xlink:href="#target"></use></svg>',
        'html-xlink-href' => '<a xlink:href="#target">Literal attribute</a>',
        'missing-href' => '<a href="missing.html">Missing guide</a>',
        'missing-src' => '<img src="missing.svg" alt="Missing fixture">',
        'missing-svg-href' => '<svg><use href="missing.svg" xlink:href="#target"></use></svg>',
        'missing-svg-xlink-href' => '<svg><use href="#target" xlink:href="missing.svg"></use></svg>',
        'missing-html-xlink-href' => '<a xlink:href="missing.html">Missing literal attribute</a>'
      }
    end

    def check_attribute_traversal
      converter = Jekyll::Converters::Markdown.new(YAML.safe_load_file(File.join(ROOT, 'site/_config.yml')))
      Dir.mktmpdir('attribute-traversal-', @public) do |root|
        File.write(File.join(root, 'fixture.svg'), '<svg xmlns="http://www.w3.org/2000/svg"></svg>')
        attribute_fixtures.each do |id, markup|
          file = File.join(root, "#{id}.html")
          File.write(file, "<main id=\"target\">#{converter.convert(markup)}</main>")
          check_svg_attribute(file, id) if id.include?('svg')
          error = document_error(file)
          if id.start_with?('missing-')
            assert(error&.start_with?('Missing rendered target:'), "Attribute #{id} was not checked: #{error}")
          else
            assert(error.nil?, "Valid attribute #{id} failed: #{error}")
          end
          @asset_results << { 'fixture' => 'attribute-traversal', 'type' => id, 'error' => error }
        end
      end
    end

    def check_svg_attribute(file, id)
      attribute = document(file).at_css('use, image, feImage').attribute_nodes.find(&:namespace)
      assert(attribute&.name == 'href' && attribute.namespace.href == 'http://www.w3.org/1999/xlink',
             "SVG fixture lost its namespaced href: #{id}")
    end

    def document_error(file)
      check_document(file)
      nil
    rescue RuntimeError => e
      e.message
    ensure
      @documents.delete(file)
    end

    def network_asset_fixtures
      fixtures = {
        'script' => '<script src="https://example.com/theme.js"></script>',
        'stylesheet' => '<link rel="stylesheet" href="//example.com/theme.css">',
        'image' => '<img src="https://example.com/image.svg" alt="External fixture">',
        'pinned-image' => '<img src="https://raw.githubusercontent.com/lost-in-the/woods/' \
                          "#{MANIFEST.fetch('release').fetch('commit')}/assets/woods-mark-black.svg\" " \
                          'alt="Pinned fixture">'
      }.merge(svg_network_asset_fixtures)
      { 'mixed-case' => 'StyleSheet', 'uppercase' => 'STYLESHEET', 'whitespace' => " \t\nStyleSheet\f\r ",
        'multiple-tokens' => "alternate\tStyleSheet\nprefetch" }.each do |id, rel|
        fixtures["stylesheet-#{id}"] = "<link rel=\"#{rel}\" href=\"https://example.com/theme.css\">"
      end
      fixtures.dup.each do |id, markup|
        %w[pre code].each { |wrapper| fixtures["#{wrapper}-#{id}"] = "<#{wrapper}>#{markup}</#{wrapper}>" }
      end
      fixtures
    end

    def check_network_assets
      converter = Jekyll::Converters::Markdown.new(YAML.safe_load_file(File.join(ROOT, 'site/_config.yml')))
      Dir.mktmpdir('network-asset-fixture-', @directory) do |root|
        network_asset_fixtures.each do |id, markup|
          file = File.join(root, "#{id}.html")
          doc = Nokogiri::HTML5("<main>#{converter.convert(markup)}</main>")
          Links.new(Object.new, {}, @base, asset_directory: root).rewrite_document(doc, 'docs/guide.md')
          File.write(file, doc.to_html)
          error = document_error(file)
          assert(error&.start_with?('Network asset'), "Network #{id} fixture unexpectedly passed: #{error}")
          @asset_results << { 'fixture' => 'network-asset', 'type' => id, 'error' => error }
        end
      end
    end
  end
end
