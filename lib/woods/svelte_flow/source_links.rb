# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Builds "view source" links for a unit's file. Shared by the live HTTP
    # source endpoint (RackMiddleware) and the offline standalone export so the
    # two produce identical links.
    module SourceLinks
      module_function

      # Anchors a repo-relative path at a recognized source root, for building
      # GitHub blob links from stored (often absolute) file paths.
      REPO_RELATIVE_RE = %r{(?:\A|/)((?:app|lib|config|spec|test|db|packs|components|frontend)/.+)\z}

      # Build a GitHub blob URL for a file, pinned to the extraction's git SHA
      # (falling back to HEAD when the SHA is missing/unknown).
      #
      # @param file_path [String, nil]
      # @param repo_url [String, nil] Base repo URL; nil disables the link
      # @param git_sha [String, nil]
      # @return [String, nil]
      def github_blob_url(file_path, repo_url:, git_sha:)
        return nil unless repo_url && file_path

        ref = git_sha && git_sha != 'unknown' ? git_sha : 'HEAD'
        "#{repo_url.chomp('/')}/blob/#{ref}/#{repo_relative_path(file_path)}"
      end

      # Reduce an absolute or app-rooted path to a repo-relative path by anchoring
      # at a recognized source root. Falls back to stripping a leading slash.
      #
      # @param file_path [String]
      # @return [String]
      def repo_relative_path(file_path)
        match = file_path.match(REPO_RELATIVE_RE)
        match ? match[1] : file_path.sub(%r{\A/}, '')
      end

      # Build a vscode://file editor link. When an editor root is configured it
      # maps the repo-relative path onto the reader's local checkout — the
      # editor-side analogue of the GitHub repo URL, needed whenever extraction
      # ran somewhere else (a container) than where the editor lives. Without a
      # root, fall back to the stored absolute path (correct when extraction
      # and editor share a filesystem); relative-only paths yield no link
      # rather than a link that cannot resolve.
      #
      # @param file_path [String, nil]
      # @param editor_root [String, nil] Absolute local project root
      # @return [String, nil]
      def editor_url(file_path, editor_root: nil)
        return nil unless file_path

        if editor_root
          "vscode://file/#{File.join(editor_root, repo_relative_path(file_path))}"
        elsif file_path.start_with?('/')
          "vscode://file/#{file_path}"
        end
      end
    end
  end
end
