# frozen_string_literal: true

module WoodsDocs
  # Share actual attribute identities and direct SVG image-resource semantics.
  module ResourceAttributes
    private

    def resource_attribute_name(attribute)
      return attribute.name unless attribute.namespace
      return 'xlink:href' if attribute.name == 'href' && attribute.namespace.href == 'http://www.w3.org/1999/xlink'

      nil
    end

    def embedded_asset?(node, name)
      return true if name == 'src'
      return false unless %w[href xlink:href].include?(name)

      node.namespace&.href == 'http://www.w3.org/2000/svg' && %w[image feImage].include?(node.name)
    end
  end

  # Resolve rendered attributes against the guide's original repository path.
  # Literal code/copy text and explicitly versioned external links stay intact.
  class Links
    include ResourceAttributes

    attr_reader :source_asset_sha256

    def initialize(repo, pages, prefix, asset_directory:)
      @repo = repo
      @pages = pages
      @prefix = prefix
      @asset_directory = asset_directory
      @source_asset_sha256 = {}
    end

    def rewrite(url, original, attribute: 'href')
      path, query, fragment = WoodsDocs.url_parts(url)
      return url if path.empty?

      relative = repository_path(path, original)
      return url unless relative

      target, kind, trailing_slash = checked_target(relative, url, original)
      source = if @pages.key?(target)
                 "#{@prefix}/#{@pages.fetch(target)}"
               else
                 unless @repo.kind(target, committed: true) == kind
                   raise "No pinned source fallback at #{@repo.sha}: #{target} (#{original})"
                 end

                 source_url(target, kind, trailing_slash, url: url, attribute: attribute)
               end
      "#{source}#{query}#{fragment}"
    end

    def rewrite_document(doc, original)
      before = doc.css('pre code').map(&:text)
      # Formatting ancestors do not make real elements/resource attributes inert.
      # Escaped examples are text nodes and never enter this walk.
      doc.css('main *').each do |node|
        node.attribute_nodes.each { |attribute| rewrite_attribute(attribute, node, original) }
      end
      raise "Code text changed while rewriting #{original}" unless before == doc.css('pre code').map(&:text)

      doc
    end

    private

    def rewrite_attribute(attribute, node, original)
      name = resource_attribute_name(attribute)
      asset = embedded_asset?(node, name)
      return unless %w[href src].include?(name) || asset

      attribute.value = rewrite(attribute.value, original, attribute: asset ? 'src' : name)
    end

    def repository_path(path, original)
      absolute = path.match(%r{\Ahttps?://github\.com/lost-in-the/woods/(?:blob|tree)/main/(.*)\z}i)
      raw = path.match(%r{\Ahttps?://raw\.githubusercontent\.com/lost-in-the/woods/main/(.*)\z}i)
      repo_absolute = path.match(%r{\A/lost-in-the/woods/(?:blob|tree)/main/(.*)\z})
      match = absolute || raw || repo_absolute
      return match[1] if match
      return nil if path.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//)}i)

      path.start_with?('/') ? path.delete_prefix('/') : File.join(File.dirname(original), path)
    end

    def checked_target(relative, url, original)
      decoded = URI::DEFAULT_PARSER.unescape(relative)
      target = Pathname.new(decoded).cleanpath.to_s
      raise "Link escapes repository: #{url} in #{original}" if target == '..' || target.start_with?('../', '/')

      # Only the synthetic fixture lives outside the selected source tree.
      kind = @pages.key?(target) ? 'blob' : @repo.kind(target)
      raise "Missing repository target: #{url} in #{original} (#{target})" unless kind

      trailing_slash = decoded.end_with?('/')
      raise "File linked as directory: #{url} in #{original}" if trailing_slash && kind != 'tree'

      [target, kind, trailing_slash]
    end

    def source_url(target, kind, trailing_slash, url:, attribute:)
      encoded = encoded_path(target)
      if attribute == 'src'
        raise "Directory cannot be an asset: #{url}" if kind == 'tree'

        stage_asset(target)
        "#{@prefix}/source-assets/#{encoded}"
      elsif WoodsDocs.url_parts(url).first.match?(%r{\Ahttps?://raw\.githubusercontent\.com/lost-in-the/woods/main/}i)
        raise "Directory cannot be an asset: #{url}" if kind == 'tree'

        "https://raw.githubusercontent.com/lost-in-the/woods/#{@repo.sha}/#{encoded}"
      else
        "#{MANIFEST.fetch('repository')}/#{kind}/#{@repo.sha}/#{encoded}#{'/' if trailing_slash}"
      end
    end

    def encoded_path(target)
      return '' if target == '.'

      target.split('/').map { |part| URI::DEFAULT_PARSER.escape(part, /[^A-Za-z0-9._~-]/) }.join('/')
    end

    # Even dirty guides embed assets from exact-revision bytes, without fetching.
    def stage_asset(target)
      return if source_asset_sha256.key?(target)

      bytes = @repo.read(target, committed: true)
      destination = File.join(@asset_directory, 'source-assets', target)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, bytes)
      source_asset_sha256[target] = Digest::SHA256.hexdigest(bytes)
    end
  end
end
