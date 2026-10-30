# frozen_string_literal: true

module WoodsDocs
  # Copy-button text must remain byte exact even when it resembles live markup.
  module CopyChecks
    private

    def check_fixture_copy(doc)
      resource_copy = "<script src=\"https://example.com/theme.js\"></script>\n" \
                      "<img src=\"https://example.com/image.svg\" alt=\"Fenced example\">\n" \
                      "<link rel=\"alternate StyleSheet\" href=\"https://example.com/theme.css\">\n"
      ["docker ps --format '{{.Names}}'\n",
       "key: unblocked-sync-${{ env.UNBLOCKED_COLLECTION_ID }}-${{ github.run_id }}\n",
       "<a href=\"../../docs/GETTING_STARTED.md\">This copy text must not be rewritten</a>\n",
       resource_copy].each do |code|
        assert(doc.css('pre code').any? { |node| node.text == code }, "Fixture copy bytes changed: #{code.inspect}")
      end
      escaped_copy = '<img src="https://example.com/image.svg" alt="Escaped example">'
      assert(doc.at_css('#escaped-resource-copy').text == escaped_copy, 'Escaped resource copy bytes changed')
      check_svg_copy(doc)
    end

    def check_svg_copy(doc)
      code = '<svg><image href="https://example.com/image.svg" ' \
             "xlink:href=\"https://example.com/fallback.svg\"></image></svg>\n"
      assert(doc.css('pre code').any? { |node| node.text == code }, 'Fenced SVG resource copy bytes changed')
      assert(doc.at_css('#escaped-svg-resource-copy').text == code.chomp, 'Escaped SVG resource copy bytes changed')
    end
  end

  # The rendered compatibility guide and its deliberately broken URL controls.
  module CompatibilityChecks
    private

    def check_fixture(version, repo)
      file = File.join(@public, version.fetch('id'), 'compatibility.html')
      doc = document(file)
      check_fixture_structure(doc)
      check_fixture_copy(doc)
      check_fixture_links(doc, version.fetch('prefix'), repo.sha)
      check_fixture_assets(doc, version)
      links = Links.new(repo, version.fetch('pages'), version.fetch('prefix'), asset_directory: File.dirname(file))
      check_negative_fixtures(links, file, version.fetch('id'))
    end

    def check_fixture_structure(doc)
      %w[fake-embeddings-ci--sandboxes--offline-hosts rails-boot-noise-breaks-mcp-protocol
         duplicate-heading duplicate-heading-1 explicit-html-anchor].each do |id|
        assert(doc.at_css("[id='#{id}']"), "Rendered fixture ID missing: #{id}")
      end
      assert(doc.at_css('a[name="named-html-anchor"]'), 'Named HTML anchor was lost')
      assert(doc.css('main table').size == 2, 'Pipe/raw HTML tables did not both render')
      assert(doc.at_css('pre code .nb, pre code .nt, pre code .na'), 'Rouge did not highlight fixture code')
    end

    def fixture_link_urls(prefix, sha)
      repository = MANIFEST.fetch('repository')
      {
        'absolute-included' => "#{prefix}/GETTING_STARTED.html?view=1&other=2",
        'root-included' => "#{prefix}/GETTING_STARTED.html",
        'excluded-file' => "#{repository}/blob/#{sha}/AGENTS.md?plain=1&other=2#commands",
        'absolute-excluded' => "#{repository}/blob/#{sha}/AGENTS.md?plain=1#commands",
        'excluded-directory' => "#{repository}/tree/#{sha}/lib/?view=tree#source",
        'escaped-file' => "#{repository}/blob/#{sha}/AGENTS.md?escaped=%2F#commands",
        'external-link' => 'https://example.com/docs/GETTING_STARTED.md?x=%2F#untouched'
      }
    end

    def check_fixture_links(doc, prefix, sha)
      fixture_link_urls(prefix, sha).each do |id, url|
        assert(doc.at_css("##{id}")['href'] == url, "Rewritten #{id} lost URL semantics")
      end
      reference = doc.css('main a').any? do |link|
        link.text == 'Reference style' && link['href'] == "#{prefix}/GETTING_STARTED.html?fixture=one&other=two"
      end
      assert(reference, 'Reference-style link failed')
    end

    def check_fixture_assets(doc, version)
      { 'relative-asset' => '?raw=1&size=2', 'absolute-asset' => '?raw=1',
        'pre-asset' => '?wrapped=pre', 'code-asset' => '?wrapped=code' }.each do |id, query|
        expected_src = "#{version.fetch('prefix')}/source-assets/assets/woods-mark-black.svg#{query}"
        assert(doc.at_css("##{id}")['src'] == expected_src, "Source asset was not staged: #{id}")
      end
      assert(doc.at_css('pre #pre-asset') && doc.at_css('code #code-asset'),
             'Live resource formatting wrappers were lost')
      assert(version.fetch('source_asset_sha256').key?('assets/woods-mark-black.svg'),
             'Rendered image was not recorded')
      check_svg_fixture_assets(doc, version)
    end

    def check_negative_fixtures(links, file, id)
      source = File.read(File.join(ROOT, 'site/fixtures/compatibility.md'))
      negatives = source.match(/<!-- negative-fixtures\n(.*?)negative-fixtures -->/m)[1]
      converter = Jekyll::Converters::Markdown.new(YAML.safe_load_file(File.join(ROOT, 'site/_config.yml')))
      rendered = Nokogiri::HTML5.fragment(converter.convert(negatives))
      rendered.css('a[href], img[src]').each do |node|
        check_negative_link(node, links, file, id)
      end
      assert(rendered.css('a[href], img[src]').size >= 8, 'Negative fixture set is absent')
    end

    def check_negative_link(node, links, file, id)
      attribute = node['href'] ? 'href' : 'src'
      error = nil
      begin
        url = links.rewrite(node[attribute], 'site/fixtures/compatibility.md', attribute: attribute)
        validate_url(url, file)
      rescue RuntimeError => e
        error = e.message
      end
      assert(error, "Broken-link fixture unexpectedly passed: #{node[attribute]}")
      @negative_results << { 'version' => id, 'url' => node[attribute], 'error' => error }
    end
  end
end
