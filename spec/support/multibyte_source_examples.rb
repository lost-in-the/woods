# frozen_string_literal: true

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

    units = with_posix_default_external { described_class.new.extract_all }

    unit = units.find { |candidate| candidate.identifier == identifier }
    expect(unit).not_to be_nil
    expect(unit.source_code).to be_valid_encoding
  end
end
