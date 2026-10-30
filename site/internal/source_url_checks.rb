# frozen_string_literal: true

module WoodsDocs
  # Reserved repository filenames must survive HTML, URL parsing and staging.
  module SourceUrlChecks
    private

    def reserved_file
      { 'original' => 'assets/diagram?draft#1%+;=&,.svg',
        'encoded' => 'assets/diagram%3Fdraft%231%25%2B%3B%3D%26%2C.svg',
        'bytes' => '<svg xmlns="http://www.w3.org/2000/svg"><path id="mark" d="M0 0"/></svg>' }
    end

    def check_source_urls
      fixture = reserved_file
      Dir.mktmpdir('source-url-fixture-', @directory) do |root|
        repo = prepare_source_repository(root, fixture)
        Dir.mktmpdir('source-url-fixture-', @public) do |published|
          check_published_source(repo, published, fixture)
        end
      end
    end

    def prepare_source_repository(root, fixture)
      fixture_git(root, 'init', '--quiet', '--initial-branch=fixture', '--template=')
      FileUtils.mkdir_p(File.join(root, 'assets'))
      File.binwrite(File.join(root, fixture.fetch('original')), fixture.fetch('bytes'))
      fixture_git(root, 'add', '--', fixture.fetch('original'))
      fixture_git(root, 'commit', '--quiet', '-m', 'Private documentation URL fixture')
      Repository.new(fixture_git(root, 'rev-parse', 'HEAD').strip, root: root)
    end

    def source_url_inputs(encoded)
      { 'relative' => "../#{encoded}",
        'absolute' => "#{MANIFEST.fetch('repository')}/blob/main/#{encoded}",
        'raw' => "https://raw.githubusercontent.com/lost-in-the/woods/main/#{encoded}" }
    end

    def check_published_source(repo, published, fixture)
      prefix = "#{@base}/#{File.basename(published)}"
      inputs = source_url_inputs(fixture.fetch('encoded'))
      doc = rewritten_source_document(repo, published, prefix, inputs)
      file = File.join(published, 'fixture.html')
      File.write(file, doc.to_html)
      check_source_inputs(doc, inputs, repo.sha, prefix, fixture)
      check_document(file)
      assert(File.binread(File.join(published, 'source-assets', fixture.fetch('original'))) == fixture.fetch('bytes'),
             'Reserved source asset bytes changed')
      @documents.delete(file)
    end

    def rewritten_source_document(repo, published, prefix, inputs)
      markup = inputs.map do |id, path|
        url = "#{path}?raw=1&amp;size=2#mark"
        "<a id=\"#{id}-link\" href=\"#{url}\">Source</a>" \
          "<img id=\"#{id}-image\" src=\"#{url}\" alt=\"Source fixture\">" \
          "<svg><image id=\"#{id}-svg\" href=\"#{url}\" xlink:href=\"#{url}\"></image></svg>"
      end.join("\n")
      converter = Jekyll::Converters::Markdown.new(YAML.safe_load_file(File.join(ROOT, 'site/_config.yml')))
      doc = Nokogiri::HTML5("<main>#{converter.convert(markup)}</main>")
      Links.new(repo, {}, prefix, asset_directory: published).rewrite_document(doc, 'docs/guide.md')
    end

    def check_source_inputs(doc, inputs, sha, prefix, fixture)
      encoded = fixture.fetch('encoded')
      inputs.each_key do |id|
        source = if id == 'raw'
                   "https://raw.githubusercontent.com/lost-in-the/woods/#{sha}/#{encoded}"
                 else
                   "#{MANIFEST.fetch('repository')}/blob/#{sha}/#{encoded}"
                 end
        check_reserved_url(doc.at_css("##{id}-link")['href'], source, fixture, id, 'href')
        check_reserved_url(doc.at_css("##{id}-image")['src'], "#{prefix}/source-assets/#{encoded}", fixture, id, 'src')
        doc.at_css("##{id}-svg").attribute_nodes.each do |attribute|
          name = resource_attribute_name(attribute)
          next unless %w[href xlink:href].include?(name)

          check_reserved_url(attribute.value, "#{prefix}/source-assets/#{encoded}", fixture, id, name)
        end
      end
    end

    def check_reserved_url(actual, path, fixture, id, attribute)
      expected = "#{path}?raw=1&size=2#mark"
      parsed = URI.parse(actual)
      assert(actual == expected, "Reserved #{attribute} URL changed: #{actual} != #{expected}")
      assert(parsed.query == 'raw=1&size=2' && parsed.fragment == 'mark', "Filename consumed query/fragment: #{actual}")
      assert(URI::DEFAULT_PARSER.unescape(parsed.path).end_with?("/#{fixture.fetch('original')}"),
             "Filename path changed: #{actual}")
      @asset_results << { 'fixture' => 'reserved-filename', 'attribute' => attribute, 'input' => id,
                          'url' => actual, 'query' => parsed.query, 'fragment' => parsed.fragment }
    end
  end
end
