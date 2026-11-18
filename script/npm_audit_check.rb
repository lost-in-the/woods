# frozen_string_literal: true

require 'date'
require 'json'
require 'yaml'

# Decides whether an `npm audit --json` report fails the build.
#
# Every advisory at moderate or above fails, unless the allowlist names its
# GHSA id and package. Decisions are made per advisory object, never per
# package: a package can carry several advisories, and the packages that
# depend on it list it only by name. An allowlist entry fails once the report
# no longer holds its advisory, and once its re-check date has passed.
#
# Run it through `script/npm-audit`.
module NpmAuditCheck
  ALLOWLIST_PATH = File.join(__dir__, 'npm_audit_allowlist.yml')
  ALLOWLIST_NAME = 'script/npm_audit_allowlist.yml'

  # Severities that do not fail the build. Any other value, known or not, does.
  BELOW_THRESHOLD = %w[info low].freeze

  GHSA = /\AGHSA(?:-[0-9a-z]{4}){3}\z/
  GHSA_IN_URL = %r{/(GHSA(?:-[0-9a-z]{4}){3})\z}
  ENTRY_KEYS = %w[ghsa package reason recheck].freeze

  # A report or allowlist that cannot be trusted.
  class Error < StandardError; end

  # The decisions for one report.
  Result = Struct.new(:lines, :failures) do
    # @return [Boolean] true when nothing fails the build
    def passed?
      failures.zero?
    end
  end

  module_function

  # @param text [String] the standard output of `npm audit --json`
  # @return [Hash] the report, once its shape is checked
  # @raise [Error] on anything but a version 2 audit report
  def parse_report(text)
    report = JSON.parse(text)
    raise Error, "npm audit did not produce a report: #{text.strip[0, 300]}" unless report_shape?(report)

    report
  rescue JSON::ParserError => e
    raise Error, "npm audit output is not JSON (#{e.message.lines.first&.strip})"
  end

  # @return [Boolean] whether every package entry is a hash whose `via` lists
  #   advisory objects or the names of other reported packages
  def report_shape?(report)
    report.is_a?(Hash) && report['auditReportVersion'] == 2 && packages_shape?(report['vulnerabilities'])
  end

  # @return [Boolean] the per-package half of {.report_shape?}
  def packages_shape?(packages)
    packages.is_a?(Hash) && packages.each_value.all? do |entry|
      entry.is_a?(Hash) && entry['via'].is_a?(Array) && entry['via'].all? { |via| via_known?(via, packages) }
    end
  end

  # @return [Boolean] whether a `via` item is an advisory object or names a reported package
  def via_known?(via, packages)
    via.is_a?(Hash) || (via.is_a?(String) && packages.key?(via))
  end

  # @param path [String] a YAML list of entries with `ghsa`, `package`, `reason` and `recheck`
  # @return [Array<Hash>] the entries, `recheck` as a Date
  # @raise [Error] when the file is unreadable or an entry is incomplete
  def load_allowlist(path)
    entries = YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [Date]) || []
    raise Error, "#{path}: expected a list of entries" unless entries.is_a?(Array)

    unique_entries(entries.map { |entry| allowlist_entry(entry, path) }, path)
  rescue SystemCallError, Psych::Exception => e
    raise Error, "#{path}: cannot read the allowlist (#{e.message})"
  end

  # @return [Array<Hash>] the entries, once no GHSA id repeats
  def unique_entries(entries, path)
    duplicate = entries.map { |entry| entry['ghsa'] }.tally.find { |_, count| count > 1 }
    raise Error, "#{path}: duplicate entry #{duplicate.first}" if duplicate

    entries
  end

  # @return [Hash] one checked entry
  def allowlist_entry(entry, path)
    unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS && entry.values_at('package', 'reason').all?(String)
      raise Error, "#{path}: each entry needs exactly #{ENTRY_KEYS.join(', ')}: #{entry.inspect}"
    end
    raise Error, "#{path}: not a GHSA id: #{entry['ghsa'].inspect}" unless GHSA.match?(entry['ghsa'].to_s)

    entry.merge('recheck' => recheck_date(entry['recheck'], path))
  end

  # @return [Date]
  def recheck_date(value, path)
    return value if value.is_a?(Date)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise Error, "#{path}: re-check date is not an ISO date: #{value.inspect}"
  end

  # @param report [Hash] the result of {.parse_report}
  # @param allowlist [Array<Hash>] the result of {.load_allowlist}
  # @param today [Date] an entry is overdue from the day after its re-check date
  # @return [Result]
  def evaluate(report, allowlist, today:)
    found = advisories(report)
    decisions = found.map { |advisory| decide(advisory, allowlist) }
    decisions += allowlist.filter_map { |entry| entry_problem(entry, found, today)&.then { |line| [line, true] } }
    Result.new(decisions.map(&:first), decisions.count(&:last))
  end

  # @return [Array<Hash>] each advisory object once, however many packages list it
  def advisories(report)
    report['vulnerabilities'].each_value.flat_map { |entry| entry['via'].grep(Hash) }
                             .uniq { |via| [via['url'], via['name']] }
  end

  # @return [Array(String, Boolean)] the decision line and whether it fails the build
  def decide(advisory, allowlist)
    ghsa = ghsa_id(advisory)
    subject = "#{ghsa || '(no GHSA id)'} #{advisory['name']} (#{advisory['severity']})"
    entry = allowlist.find { |candidate| listed?(candidate, advisory) }
    if entry
      ["allowed #{subject}: #{entry['reason']} (re-check by #{entry['recheck'].iso8601})", false]
    elsif ghsa && BELOW_THRESHOLD.include?(advisory['severity'])
      ["below threshold #{subject}: #{advisory['title']}", false]
    else
      ["blocked #{subject}: #{advisory['title']}", true]
    end
  end

  # @return [String, nil] the GHSA id that ends the advisory's url
  def ghsa_id(advisory)
    advisory['url'].to_s[GHSA_IN_URL, 1]
  end

  # @return [Boolean] whether the entry names this advisory's id and package
  def listed?(entry, advisory)
    ghsa_id(advisory) == entry['ghsa'] && advisory['name'] == entry['package']
  end

  # @return [String, nil] why an allowlist entry fails, if it does
  def entry_problem(entry, found, today)
    subject = "#{entry['ghsa']} #{entry['package']}"
    present = found.any? { |advisory| listed?(entry, advisory) }
    return "stale entry #{subject}: not in the audit report; remove it from #{ALLOWLIST_NAME}" unless present
    return if today <= entry['recheck']

    "overdue entry #{subject}: re-check date #{entry['recheck'].iso8601} has passed; " \
      're-evaluate the advisory and update or remove the entry'
  end
end
