# frozen_string_literal: true

require 'digest'

module CodebaseIndex
  # Shared filename helpers for converting unit identifiers to safe filenames.
  #
  # Used by Extractor (writing) and IndexValidator (reading) to ensure
  # filename generation is consistent across both sides.
  module FilenameUtils
    # Convert an identifier to a safe filename (legacy format).
    #
    # @param identifier [String] The unit identifier (e.g., "Admin::UsersController")
    # @return [String] A filesystem-safe filename (e.g., "Admin__UsersController.json")
    def safe_filename(identifier)
      "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
    end

    # Convert an identifier to a collision-safe filename (current format).
    #
    # Appends a short SHA256 digest to disambiguate identifiers that normalize
    # to the same safe_filename.
    #
    # @param identifier [String] The unit identifier
    # @return [String] Collision-safe filename (e.g., "Admin__UsersController_a1b2c3d4.json")
    def collision_safe_filename(identifier)
      base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
      digest = Digest::SHA256.hexdigest(identifier)[0, 8]
      "#{base}_#{digest}.json"
    end
  end
end
