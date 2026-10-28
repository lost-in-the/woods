# frozen_string_literal: true

module WoodsDocs
  # The local preview must serve static bytes and version-aware errors for GET/HEAD.
  module HttpChecks
    private

    def check_http
      log = StringIO.new
      server = WoodsDocs.server(@base, port: 0, logger: WEBrick::Log.new(log, WEBrick::Log::FATAL))
      thread = Thread.new { server.start }
      http = preview_http(server.listeners.first.addr[1])
      begin
        check_http_hub(http)
        @metadata.fetch('versions').each { |version| check_http_version(http, version) }
        missing = http.get("#{@base}/not-a-version/not-a-guide")
        assert(missing.code == '404' && missing.body.include?('Choose a documentation version'), 'Hub HTTP 404 failed')
      ensure
        server.shutdown
        thread.join(5)
      end
    end

    def check_http_hub(http)
      response = http.get("#{@base}/")
      assert(response.code == '200' && response.body.include?('Choose the documentation'), 'HTTP hub failed')
    end

    def preview_http(port)
      http = Net::HTTP.new('127.0.0.1', port, nil)
      http.open_timeout = 5
      http.read_timeout = 5
      http
    end

    def check_http_version(http, version)
      check_static_file(http, version)
      prefix = version.fetch('prefix')
      redirect = http.get(prefix)
      assert(redirect.code == '301' && URI.parse(redirect['location']).path == "#{prefix}/",
             "HTTP directory redirect failed: #{prefix}")
      assert(http.get("#{prefix}/").code == '200', "HTTP directory index failed: #{prefix}")
      check_http_pages(http, prefix)
      check_http_missing(http, version)
      ['/', '/missing/nested'].each { |suffix| check_http_file_suffix(http, version, suffix) }
    end

    def check_http_pages(http, prefix)
      page = http.get("#{prefix}/GETTING_STARTED.html")
      assert(page.code == '200', "HTTP guide failed: #{prefix}")
      data = http.get("#{prefix}/assets/js/search-data.json")
      assert(data.code == '200' && !JSON.parse(data.body).empty?, "HTTP search JSON failed: #{prefix}")
    end

    def check_http_missing(http, version)
      prefix = version.fetch('prefix')
      missing = http.get("#{prefix}/not-a-guide/nested")
      assert(missing.code == '404' && missing.body.include?('Page not found') &&
             missing.body.include?("data-docs-version=\"#{version.fetch('id')}\""),
             "Version HTTP 404 failed: #{prefix}")
      head = http.head("#{prefix}/not-a-guide")
      assert(head.code == '404' && head.body.nil?, "HTTP HEAD 404 failed: #{prefix}")
    end

    def check_http_file_suffix(http, version, suffix)
      path = "#{version.fetch('prefix')}/GETTING_STARTED.html#{suffix}"
      missing = http.get(path)
      expected_body = File.binread(File.join(@public, version.fetch('id'), '404.html'))
      assert(missing.code == '404' && missing.body == expected_body, "HTTP file suffix GET failed: #{path}")
      head = http.head(path)
      assert(head.code == '404' && head.body.nil? && head['content-length'] == expected_body.bytesize.to_s,
             "HTTP file suffix HEAD failed: #{path}")
      @http_results << { 'path' => path, 'GET' => missing.code, 'HEAD' => head.code, 'version' => version.fetch('id') }
    end

    def check_static_file(http, version)
      # A harmless arithmetic template exercises WEBrick's rhtml extension map.
      # GET and HEAD must serve its literal bytes rather than evaluate it.
      Dir.mktmpdir('static-file-fixture-', File.join(@public, version.fetch('id'))) do |root|
        bytes = '<%= 6 * 7 %>'
        File.binwrite(File.join(root, 'example.rhtml'), bytes)
        path = "#{version.fetch('prefix')}/#{File.basename(root)}/example.rhtml"
        get = http.get(path)
        head = http.head(path)
        assert_static_response(get, bytes, path, 'GET')
        assert_static_response(head, bytes, path, 'HEAD')
        @http_results << { 'fixture' => 'static-rhtml', 'path' => path, 'GET' => get.code,
                           'HEAD' => head.code, 'body' => get.body, 'content_length' => head['content-length'],
                           'version' => version.fetch('id') }
      end
    end

    def assert_static_response(response, bytes, path, method)
      body_matches = method == 'HEAD' ? response.body.nil? : response.body == bytes
      assert(response.code == '200' && body_matches && response['content-length'] == bytes.bytesize.to_s,
             "HTTP static rhtml #{method} failed: #{path}")
    end
  end
end
