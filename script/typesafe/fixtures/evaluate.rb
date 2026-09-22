# frozen_string_literal: true

require_relative 'evaluator/runner'

begin
  raise ArgumentError, 'usage: ruby evaluate.rb' unless ARGV.empty?

  report = FixtureRunner.run(__dir__)
  puts JSON.pretty_generate(report)
  exit FixtureRunner.exit_status(report)
rescue StandardError, ScriptError => e
  puts JSON.generate(error: "#{e.class}: #{e.message}", status: 'infrastructure_error')
  exit 2
end
