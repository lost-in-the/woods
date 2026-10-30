# frozen_string_literal: true

module WoodsDocs
  # Guide text, provenance and page-preserving version navigation.
  module GuideChecks
    private

    def check_guide(version, repo, original, digest)
      id = version.fetch('id')
      body = repo.read(original)
      assert(Digest::SHA256.hexdigest(body) == digest, "Source changed since build: #{original} (#{id})")
      path = File.join(@public, id, version.fetch('pages').fetch(original))
      doc = document(path)
      check_liquid_copy(doc, body, "#{id}/#{original}")
      check_guide_provenance(doc, version, original)
      doc.css('.woods-context nav a').each { |link| check_version_link(link, version.fetch('pages').fetch(original)) }
    end

    def check_guide_provenance(doc, version, original)
      id = version.fetch('id')
      banner = doc.at_css('.woods-context').text
      assert(banner.include?(version.fetch('sha')), "Provenance SHA absent: #{id}/#{original}")
      return unless id == 'unreleased' && !@metadata.fetch('checkout_status').empty?

      assert(banner.include?('dirty checkout') && banner.include?('uncommitted'), 'Dirty provenance is concealed')
    end

    def check_liquid_copy(doc, body, label)
      # These are the actual pre/code nodes read by the theme's copy button.
      body.scan(/^```[^\n]*\n(.*?)^```[ \t]*$/m).flatten.grep(/\{\{/).each do |code|
        assert(doc.css('pre code').any? { |node| node.text == code }, "Liquid/copy bytes changed in #{label}")
      end
      body.scan(/`([^`\n]*\{\{[^`\n]*)`/).flatten.each do |code|
        assert(doc.css('code').any? { |node| node.text == code }, "Inline Liquid bytes changed in #{label}: #{code}")
      end
    end

    def check_version_link(link, output)
      other = @metadata.fetch('versions').find { |entry| link['href'].start_with?("#{entry.fetch('prefix')}/") }
      assert(other, "Unknown version link: #{link['href']}")
      present = other.fetch('pages').value?(output)
      expected = "#{other.fetch('prefix')}/#{output if present}"
      assert(link['href'] == expected, "Version picker lost page/fallback: #{link['href']} != #{expected}")
      assert(present || link.text.include?('guide unavailable'), 'Unexplained version fallback')
    end
  end

  # Each version's sources, omissions and locally searchable artifact.
  module VersionChecks
    private

    def check_version(version)
      repo = Repository.new(version.fetch('sha'), working: version.fetch('id') == 'unreleased')
      check_source_assets(version, repo)
      version.fetch('guide_sha256').each { |original, digest| check_guide(version, repo, original, digest) }
      check_missing_guides(version)
      check_search(version)
      check_fixture(version, repo)
    end

    def check_source_assets(version, repo)
      id = version.fetch('id')
      version.fetch('source_asset_sha256').each do |original, digest|
        expected = Digest::SHA256.hexdigest(repo.read(original, committed: true))
        staged = File.join(@public, id, 'source-assets', original)
        assert(digest == expected, "Source asset is not pinned: #{id}/#{original}")
        assert(Digest::SHA256.file(staged).hexdigest == expected, "Staged asset bytes changed: #{id}/#{original}")
      end
    end

    def check_missing_guides(version)
      return if version.fetch('missing_guides').empty?

      landing = document(File.join(@public, version.fetch('id'), 'index.html')).text
      assert(landing.include?('did not exist at the pinned release'), 'Historical omissions are not explained')
      version.fetch('missing_guides').each do |path|
        assert(landing.include?(path), "Missing guide not listed: #{path}")
      end
    end

    def check_search(version)
      root = File.join(@public, version.fetch('id'))
      prefix = version.fetch('prefix')
      search = JSON.parse(File.read(File.join(root, 'assets/js/search-data.json')))
      assert(search.size > version.fetch('guide_sha256').size,
             "Empty or incomplete search index: #{version.fetch('id')}")
      search.each_value do |entry|
        assert(entry.fetch('url').start_with?("#{prefix}/"), "Search escaped version: #{entry.fetch('url')}")
        validate_url(entry.fetch('url'), File.join(root, 'index.html'))
        assert(!entry.fetch('url').include?('/compatibility.html'), 'Test fixture leaked into search')
      end
      check_search_script(root, prefix)
    end

    def check_search_script(root, prefix)
      script = File.read(File.join(root, 'assets/js/just-the-docs.js'))
      assert(script.include?("#{prefix}/assets/js/search-data.json"), 'Search fetch is not version local')
      assert(script.include?('window.navigator.clipboard.writeText(code)'), 'Theme copy handler is absent')
    end
  end
end
