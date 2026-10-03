# frozen_string_literal: true

# Runs a block with the default external encoding a POSIX locale gives Ruby
# (`LANG=C`): US-ASCII. A bare File.read then tags source US-ASCII, so a
# reader that relies on the locale fails here even in a UTF-8 test run.
module PosixDefaultExternal
  # @yield the code under test
  # @return [Object] the block's value
  def with_posix_default_external
    original_encoding = Encoding.default_external
    original_verbose = $VERBOSE
    begin
      $VERBOSE = nil # Ruby warns when the default external encoding is reassigned.
      Encoding.default_external = Encoding::US_ASCII
      yield
    ensure
      Encoding.default_external = original_encoding
      $VERBOSE = original_verbose
    end
  end
end

RSpec.configure { |config| config.include PosixDefaultExternal }
