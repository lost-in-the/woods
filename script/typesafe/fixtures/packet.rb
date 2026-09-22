# frozen_string_literal: true

require 'json'

begin
  id = ARGV.fetch(0)
  raise ArgumentError, 'provide exactly one opaque case ID' unless ARGV.size == 1 && id.match?(/\A[0-9a-f]{8}\z/)

  directory = File.join(__dir__, 'cases', id)
  files = %w[before.rb source.rb change.patch test.rb].to_h do |name|
    [name, File.read(File.join(directory, name))]
  end
  files['LICENSE.txt'] = File.read(File.join(__dir__, 'LICENSE.txt'))
  puts JSON.pretty_generate(schema_version: 1, case_id: id, task: File.read(File.join(directory, 'context.md')),
                            files: files)
rescue StandardError
  puts JSON.generate(error: 'usage: ruby packet.rb CASE_ID (existing eight-character case ID required)')
  exit 2
end
