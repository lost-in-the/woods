# frozen_string_literal: true

require 'spec_helper'
require 'date'
require 'json'
require 'tmpdir'
require_relative '../../script/npm_audit_check'

RSpec.describe NpmAuditCheck do
  let(:fixture) { File.read(File.expand_path('../fixtures/npm_audit/report.json', __dir__)) }
  let(:report) { JSON.parse(fixture) }
  let(:today) { Date.new(2026, 11, 17) }
  let(:picomatch_entry) do
    { 'ghsa' => 'GHSA-fc5q-39xc-vjpf', 'package' => 'picomatch',
      'reason' => 'upstream disputes the report', 'recheck' => Date.new(2027, 2, 15) }
  end
  let(:allowlist) { [picomatch_entry] }

  def advisory(ghsa, name:, severity: 'high')
    { 'source' => 1, 'name' => name, 'dependency' => name, 'title' => "#{name} advisory",
      'url' => "https://github.com/advisories/#{ghsa}", 'severity' => severity, 'range' => '*' }
  end

  def add_via(package, entry)
    report['vulnerabilities'].fetch(package)['via'] << entry
  end

  def add_package(name, *via)
    report['vulnerabilities'][name] = { 'name' => name, 'severity' => 'high', 'via' => via, 'effects' => [] }
  end

  def check(list = allowlist, on: today)
    described_class.evaluate(report, list, today: on)
  end

  it 'passes the real report when its only advisory is allowlisted, and says why' do
    result = check

    expect(result).to be_passed
    expect(result.lines).to eq(
      ['allowed GHSA-fc5q-39xc-vjpf picomatch (high): upstream disputes the report (re-check by 2027-02-15)']
    )
  end

  it 'blocks a second, unlisted advisory on the allowlisted package' do
    add_via('picomatch', advisory('GHSA-aaaa-bbbb-cccc', name: 'picomatch', severity: 'moderate'))

    result = check

    expect(result).not_to be_passed
    expect(result.lines).to include('blocked GHSA-aaaa-bbbb-cccc picomatch (moderate): picomatch advisory')
    expect(result.lines.grep(/\Aallowed GHSA-fc5q-39xc-vjpf/).size).to eq(1)
  end

  it 'blocks an unlisted advisory on a package that depends on the allowlisted one' do
    add_via('vite', advisory('GHSA-dddd-eeee-ffff', name: 'vite', severity: 'critical'))

    expect(check.lines).to include('blocked GHSA-dddd-eeee-ffff vite (critical): vite advisory')
    expect(check).not_to be_passed
  end

  it 'blocks an unlisted advisory on an unrelated package' do
    add_package('left-pad', advisory('GHSA-gggg-hhhh-jjjj', name: 'left-pad'))

    expect(check).not_to be_passed
    expect(check.lines).to include('blocked GHSA-gggg-hhhh-jjjj left-pad (high): left-pad advisory')
  end

  it 'lets a low or info advisory through, naming it' do
    add_package('left-pad', advisory('GHSA-gggg-hhhh-jjjj', name: 'left-pad', severity: 'low'),
                advisory('GHSA-kkkk-mmmm-nnnn', name: 'left-pad', severity: 'info'))

    result = check

    expect(result).to be_passed
    expect(result.lines).to include('below threshold GHSA-gggg-hhhh-jjjj left-pad (low): left-pad advisory',
                                    'below threshold GHSA-kkkk-mmmm-nnnn left-pad (info): left-pad advisory')
  end

  it 'blocks an advisory whose severity it does not recognise' do
    add_package('left-pad', advisory('GHSA-gggg-hhhh-jjjj', name: 'left-pad', severity: 'severe'))

    expect(check).not_to be_passed
  end

  it 'blocks an advisory with no GHSA id in its url' do
    add_package('left-pad', advisory('GHSA-gggg-hhhh-jjjj', name: 'left-pad').merge('url' => 'https://example.test/1'))

    expect(check.lines).to include('blocked (no GHSA id) left-pad (high): left-pad advisory')
    expect(check).not_to be_passed
  end

  it 'reports an advisory listed under several packages once' do
    add_via('fdir', report['vulnerabilities']['picomatch']['via'].first)

    expect(check.lines.size).to eq(1)
  end

  it 'invents nothing from packages affected only through a dependency' do
    report['vulnerabilities'].delete('picomatch')
    report['vulnerabilities'].each_value { |entry| entry['via'] = entry['via'] - ['picomatch'] }

    result = check

    expect(result.lines.grep(/\A(?:allowed|blocked)/)).to be_empty
    expect(result.lines).to eq(['stale entry GHSA-fc5q-39xc-vjpf picomatch: not in the audit report; ' \
                                'remove it from script/npm_audit_allowlist.yml'])
  end

  it 'fails a stale entry whose advisory the report no longer holds' do
    report['vulnerabilities'] = {}

    expect(check).not_to be_passed
    expect(check.lines.first).to start_with('stale entry GHSA-fc5q-39xc-vjpf picomatch: not in the audit report')
  end

  it 'blocks the advisory and fails the entry when the id moves to another package' do
    via = report['vulnerabilities']['picomatch']['via'].first
    via['name'] = 'other-glob'
    report['vulnerabilities']['other-glob'] = report['vulnerabilities'].delete('picomatch')

    expect(check).not_to be_passed
    expect(check.lines).to include(start_with('blocked GHSA-fc5q-39xc-vjpf other-glob (high)'),
                                   start_with('stale entry GHSA-fc5q-39xc-vjpf picomatch'))
  end

  it 'still allows on the re-check date itself' do
    expect(check(on: Date.new(2027, 2, 15))).to be_passed
  end

  it 'fails an entry the day after its re-check date' do
    result = check(on: Date.new(2027, 2, 16))

    expect(result).not_to be_passed
    expect(result.failures).to eq(1)
    expect(result.lines).to eq(
      ['allowed GHSA-fc5q-39xc-vjpf picomatch (high): upstream disputes the report (re-check by 2027-02-15)',
       'overdue entry GHSA-fc5q-39xc-vjpf picomatch: re-check date 2027-02-15 has ' \
       'passed; re-evaluate the advisory and update or remove the entry']
    )
  end

  describe '.parse_report' do
    it 'parses a real audit report' do
      expect(described_class.parse_report(fixture)['auditReportVersion']).to eq(2)
    end

    {
      'empty output' => '',
      'malformed JSON' => '{"auditReportVersion": 2,',
      'a missing lockfile' => '{"error":{"code":"ENOLOCK","summary":"This command requires an existing lockfile."}}',
      'a network failure' => '{"message":"request to https://registry.test failed, reason: ECONNREFUSED"}',
      'another report version' => '{"auditReportVersion":1,"advisories":{}}',
      'a non-object package' => '{"auditReportVersion":2,"vulnerabilities":{"x":[]}}',
      'a via that is not a list' => '{"auditReportVersion":2,"vulnerabilities":{"x":{"via":"y"}}}',
      'a via naming no reported package' => '{"auditReportVersion":2,"vulnerabilities":{"x":{"via":["y"]}}}',
      'a via of another type' => '{"auditReportVersion":2,"vulnerabilities":{"x":{"via":[1]}}}'
    }.each do |label, text|
      it "fails closed on #{label}" do
        expect { described_class.parse_report(text) }.to raise_error(NpmAuditCheck::Error)
      end
    end
  end

  describe '.load_allowlist' do
    def load(text)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'allowlist.yml')
        File.write(path, text)
        described_class.load_allowlist(path)
      end
    end

    let(:entry_yaml) do
      "- ghsa: GHSA-fc5q-39xc-vjpf\n  package: picomatch\n  reason: disputed\n  recheck: 2027-02-15\n"
    end

    it 'loads the checked-in allowlist with the picomatch entry' do
      entries = described_class.load_allowlist(NpmAuditCheck::ALLOWLIST_PATH)

      expect(entries.map { |e| [e['ghsa'], e['package'], e['recheck']] })
        .to eq([['GHSA-fc5q-39xc-vjpf', 'picomatch', Date.new(2027, 2, 15)]])
      expect(entries.first['reason']).to include('disputes', 'no patched release', 'test-only', 'glob')
    end

    it 'reads an ISO date, quoted or not' do
      expect(load(entry_yaml).first['recheck']).to eq(Date.new(2027, 2, 15))
      expect(load(entry_yaml.sub('2027-02-15', "'2027-02-15'")).first['recheck']).to eq(Date.new(2027, 2, 15))
    end

    it 'reads a file holding only comments as an empty allowlist' do
      expect(load("# Advisories script/npm-audit lets through.\n")).to eq([])
    end

    it 'fails closed on an unreadable file' do
      expect { described_class.load_allowlist('/nonexistent/allowlist.yml') }.to raise_error(NpmAuditCheck::Error)
    end

    {
      'malformed YAML' => "- ghsa: [\n",
      'a non-list document' => "ghsa: GHSA-fc5q-39xc-vjpf\n",
      'a missing reason' => "- ghsa: GHSA-fc5q-39xc-vjpf\n  package: picomatch\n  recheck: 2027-02-15\n",
      'a bad id' => "- ghsa: CVE-2026-1\n  package: picomatch\n  reason: r\n  recheck: 2027-02-15\n",
      'a bad date' => "- ghsa: GHSA-fc5q-39xc-vjpf\n  package: picomatch\n  reason: r\n  recheck: soon\n"
    }.each do |label, text|
      it "fails closed on #{label}" do
        expect { load(text) }.to raise_error(NpmAuditCheck::Error)
      end
    end

    it 'fails closed on a duplicate id' do
      expect { load(entry_yaml * 2) }.to raise_error(NpmAuditCheck::Error, /duplicate/)
    end
  end
end
