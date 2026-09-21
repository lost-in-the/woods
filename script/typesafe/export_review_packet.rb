# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require_relative 'review_packet'

# No Rails boot, subprocess, model client, credential lookup or source evaluation.
if ARGV.length != 3
  warn 'Usage: bundle exec ruby script/typesafe/export_review_packet.rb SOURCE_ROOT INDEX_ROOT SELECTION.json'
  exit 2
end

begin
  selection_path = ARGV.fetch(2)
  raise WoodsDevelopment::TypeSafe::InvalidEvidence unless File.file?(selection_path)

  selection_bytes = File.open(selection_path, 'rb') { |file| file.read(131_073) || ''.b }
  raise WoodsDevelopment::TypeSafe::InvalidEvidence if selection_bytes.bytesize > 131_072

  manifest = JSON.parse(selection_bytes.force_encoding(Encoding::UTF_8))
  packet = WoodsDevelopment::TypeSafe::ReviewPacket.build(root: ARGV.fetch(0), index_dir: ARGV.fetch(1),
                                                          manifest: manifest)
  puts JSON.generate(packet)
rescue WoodsDevelopment::TypeSafe::InvalidEvidence, JSON::JSONError, SystemCallError, IOError, EncodingError
  warn 'Cannot export review packet: invalid, oversized or unreadable evidence/index; no packet emitted'
  exit 2
end
