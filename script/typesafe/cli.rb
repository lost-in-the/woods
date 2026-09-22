# frozen_string_literal: true

require_relative 'replay'

# No network/authentication dependency: capture is still an explicit experiment.
if ARGV.length != 2 || ARGV.first != 'replay'
  warn 'Usage: ruby script/typesafe/cli.rb replay CAPTURE.json'
  exit 2
end

begin
  report = WoodsDevelopment::TypeSafe::Replay.read(ARGV.last)
  puts JSON.pretty_generate(report)
  exit(report.fetch('errors').zero? ? 0 : 1)
rescue WoodsDevelopment::TypeSafe::InvalidEvidence, JSON::JSONError, SystemCallError, EncodingError
  warn 'Cannot replay: invalid or unreadable evidence'
  exit 2
end
