# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'oracles'

module FixtureRunner
  module_function

  def evaluate(root, row)
    directory = File.join(root, 'cases', row.fetch('case_id'))
    verify_files(directory, row.fetch('sha256'))
    before = exercise(directory, 'before.rb', row.fetch('family'))
    after = exercise(directory, 'source.rb', row.fetch('family'))
    observed = after.fetch(:checks).all? { |check| check.fetch(:passed) } ? 'satisfied' : 'regression'
    summarize(row, before, after, observed)
  rescue StandardError, ScriptError => e
    { case_id: row.fetch('case_id'), status: 'infrastructure_error', error: "#{e.class}: #{e.message}" }
  end

  def verify_files(directory, hashes)
    hashes.each do |name, expected|
      actual = Digest::SHA256.file(File.join(directory, name)).hexdigest
      raise ArgumentError, "fixture integrity mismatch: #{name}" unless actual == expected
    end
  end

  def exercise(directory, filename, family)
    scope = Module.new
    path = File.join(directory, filename)
    scope.module_eval(File.read(path), path)
    checks = FixtureOracles.public_send(family, scope)
    smoke = File.join(directory, 'test.rb')
    scope.module_eval(File.read(smoke), smoke)
    { smoke_satisfied: true, checks: checks }
  end

  def summarize(row, before, after, observed)
    baseline = before.fetch(:checks).all? { |check| check.fetch(:passed) }
    verified = baseline && observed == row.fetch('expected')
    { case_id: row.fetch('case_id'), family: row.fetch('family'), expected: row.fetch('expected'),
      observed: observed, status: verified ? 'verified' : 'unexpected_behavior',
      baseline_satisfied: baseline, smoke_satisfied: after.fetch(:smoke_satisfied), checks: after.fetch(:checks) }
  end

  def run(root)
    manifest = JSON.parse(File.read(File.join(root, 'evaluator', 'cases.json')))
    cases = manifest.fetch('cases').map { |row| evaluate(root, row) }
    { schema_version: 1, purpose: 'fixture_behavior_validation_only', cases: cases }
  end

  def exit_status(report)
    statuses = report.fetch(:cases).map { |row| row.fetch(:status) }
    return 2 if statuses.include?('infrastructure_error')

    statuses.all? { |status| status == 'verified' } ? 0 : 1
  end
end
