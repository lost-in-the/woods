# frozen_string_literal: true

require 'webrick'
require_relative 'build'

module WoodsDocs
  # FileHandler supplies ordinary MIME types, HEAD and directory redirects. A
  # missing path must serve the appropriate 404 document with status 404.
  class Files < WEBrick::HTTPServlet::FileHandler
    def service(request, response)
      # FileHandler consumes path_info while looking for a target.
      version = request.path_info.split('/')[1]
      super
    rescue WEBrick::HTTPStatus::NotFound
      candidate = File.join(@root, version.to_s, '404.html')
      candidate = File.join(@root, '404.html') unless %w[unreleased v2.1.0].include?(version) && File.file?(candidate)
      response.status = 404
      response['Content-Type'] = 'text/html; charset=utf-8'
      response.body = File.read(candidate)
    end

    private

    # Bypass FileHandler's extension dispatch, including its global ERB/CGI
    # fallback. Every published file must be served as static bytes.
    def get_handler(_request, _response)
      WEBrick::HTTPServlet::DefaultFileHandler
    end
  end

  def self.server(base, port:, logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))
    base = baseurl(base)
    root = File.join(build_dir(base), 'public')
    raise "Build #{base.empty? ? '/' : base} first: #{root} is absent" unless File.file?(File.join(root, 'index.html'))

    server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: port, Logger: logger, AccessLog: [])
    server.mount(
      base.empty? ? '/' : base, Files, root,
      FancyIndexing: false,
      FileCallback: lambda do |request, _response|
        # WEBrick may resolve an existing file while retaining a URL suffix.
        # Reject it before DefaultFileHandler opens the file.
        raise WEBrick::HTTPStatus::NotFound unless request.path_info.empty?
      end
    )
    server
  end
end

if $PROGRAM_NAME == __FILE__
  options = { baseurl: '', port: 4015 }
  OptionParser.new do |parser|
    parser.on('--baseurl PATH') { |value| options[:baseurl] = value }
    parser.on('--port PORT', Integer) { |value| options[:port] = value }
  end.parse!
  server = WoodsDocs.server(options.fetch(:baseurl), port: options.fetch(:port))
  %w[INT TERM].each { |signal| trap(signal) { server.shutdown } }
  puts "Serving http://localhost:#{options.fetch(:port)}#{options.fetch(:baseurl)}/ (Ctrl-C to stop)"
  server.start
end
