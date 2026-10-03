# frozen_string_literal: true

# Emulates a POSIX-locale host (LANG=C / LC_ALL=C, the default in a plain
# container image), where Ruby's default external encoding is US-ASCII and a
# bare File.read tags multibyte host source as an invalid US-ASCII string.
#
# The suite normally runs under a UTF-8 locale, so a regressed reader passes
# unless the spec forces the encoding itself.
module UsAsciiDefaultExternal
  # @yield runs with Encoding.default_external set to US-ASCII
  # @return [Object] the block's value
  def with_us_ascii_default_external
    original = Encoding.default_external
    verbose = $VERBOSE
    # Ruby warns when the default external encoding is reassigned.
    $VERBOSE = nil
    Encoding.default_external = Encoding::US_ASCII
    $VERBOSE = verbose
    yield
  ensure
    $VERBOSE = nil
    Encoding.default_external = original
    $VERBOSE = verbose
  end
end

RSpec.configure do |config|
  config.include UsAsciiDefaultExternal
end

# A real source file with a multibyte character, extracted under a US-ASCII
# default external encoding, must still yield its unit. Needs the
# 'extractor setup' context (create_file) and an extractor whose
# `described_class.new.extract_all` discovers +path+.
#
# @param path [String] file to create, relative to the stubbed Rails.root
# @param source [String] file content; must contain a multibyte character
# @param identifier [String] identifier the extracted unit must carry
RSpec.shared_examples 'extracts multibyte source under a POSIX locale' do |path:, source:, identifier:|
  it "still extracts #{identifier} when #{path} holds a multibyte character" do
    create_file(path, source)

    units = with_us_ascii_default_external { described_class.new.extract_all }

    unit = units.find { |candidate| candidate.identifier == identifier }
    expect(unit).not_to be_nil
    expect(unit.source_code).to be_valid_encoding
  end
end
