# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require_relative '../../../script/typesafe/replay'

RSpec.describe WoodsDevelopment::TypeSafe::Replay do
  let(:profiles) { WoodsDevelopment::TypeSafe::Profiles }
  let(:choice) { JSON.parse(File.read(File.expand_path('../../../script/typesafe/assessment.json', __dir__))) }
  let(:request) do
    { 'model' => 'jev-1.13.0', 'state' => { 'invariant' => 'returns 2', 'test_source' => 'expect(call).to eq(2)' },
      'questions' => profiles.questions(choice) }
  end
  let(:answers) do
    signals = profiles::SIGNALS.to_h do |key|
      [key, { 'type' => 'noul', 'noul' => %w[missing_context wrong_result].include?(key) ? 0.1 : 0.9 }]
    end
    signals.merge('assessment' => {
                    'type' => 'choice', 'choice' => 'direct', 'confidence' => 0.9,
                    'probabilities' => { 'direct' => 0.9, 'weak' => 0.05,
                                         'absent_in_packet' => 0.03, 'insufficient_context' => 0.02 }
                  })
  end
  let(:entry) do
    { 'id' => 'one', 'family' => 'family', 'label' => 'direct', 'complete' => true,
      'request' => request, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(request)),
      'response' => { 'model' => 'jev-1.13.0', 'answers' => answers,
                      'usage' => { 'input_tokens' => 100, 'output_tokens' => 20 } } }
  end
  let(:document) { { 'schema_version' => 1, 'cases' => [entry] } }

  def replay
    described_class.new(document).report
  end

  def resign
    entry['request_sha256'] = Digest::SHA256.hexdigest(JSON.generate(request))
  end

  it 'retains supported direct evidence without network or credential access' do
    expect(replay).to include('intended' => 1, 'completed' => 1, 'direct_retained' => 1, 'errors' => 0)
  end

  it 'routes a conflicting full-invariant signal to review' do
    answers['entire_invariant']['noul'] = 0.5
    expect(replay).to include('direct_retained' => 0, 'review_count' => 1, 'raw_exact_matches' => 1)
  end

  it 'does not average away a wrong-receiver flag' do
    answers['wrong_result']['noul'] = 0.9
    expect(replay.fetch('rows').first['effective']).to eq('review')
  end

  it 'never upgrades weak evidence even when all added signals are favorable' do
    answers['assessment'].merge!('choice' => 'weak', 'probabilities' => {
                                   'direct' => 0.05, 'weak' => 0.9,
                                   'absent_in_packet' => 0.03, 'insufficient_context' => 0.02
                                 })
    expect(replay.fetch('rows').first['effective']).to eq('weak')
  end

  it 'retains raw false reassurance when incomplete evidence overrides the effective route' do
    entry.merge!('label' => 'insufficient_context', 'complete' => false)
    expect(replay).to include('raw_false_direct' => 1, 'effective_false_direct' => 0, 'review_count' => 1)
  end

  it 'accepts a standalone Choice comparator' do
    request['questions'] = { 'assessment' => choice }
    entry['response']['answers'] = { 'assessment' => answers.fetch('assessment') }
    resign
    expect(replay.fetch('completed')).to eq(1)
  end

  it 'keeps missing responses in intended denominators' do
    entry['response'] = nil
    expect(replay).to include('intended' => 1, 'completed' => 0, 'errors' => 1, 'raw_exact_matches' => 0)
  end

  it 'rejects mismatched input hashes' do
    entry
    request['state']['invariant'] = 'changed'
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'rejects duplicate case IDs' do
    document['cases'] << entry.dup
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'rejects unknown fields in provider state, including labels' do
    request['state']['label'] = 'direct'
    resign
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'rejects incomplete signal sets instead of silently disabling the veto' do
    request['questions'].delete('wrong_result')
    resign
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'reports wrong model identity as an operational error' do
    entry['response']['model'] = 'another-model'
    expect(replay.fetch('errors')).to eq(1)
  end

  it 'reports missing answer IDs as an operational error' do
    answers.delete('entire_invariant')
    expect(replay.fetch('errors')).to eq(1)
  end

  [Float::NAN, Float::INFINITY, -0.1, 1.1, '0.8', nil, true].each do |invalid|
    it "rejects invalid Noul value #{invalid.inspect}" do
      answers['entire_invariant']['noul'] = invalid
      expect(replay.fetch('errors')).to eq(1)
    end
  end

  it 'rejects a Choice whose winner disagrees with its distribution' do
    answers['assessment']['choice'] = 'weak'
    expect(replay.fetch('errors')).to eq(1)
  end

  it 'rejects an incomplete probability distribution' do
    answers['assessment']['probabilities'].delete('weak')
    expect(replay.fetch('errors')).to eq(1)
  end

  it 'rejects negative reported token usage' do
    entry['response']['usage']['input_tokens'] = -1
    expect(replay.fetch('errors')).to eq(1)
  end

  it 'rejects a changed Noul meaning even when its request hash matches' do
    request['questions']['entire_invariant']['instructions'] = 'Do assertions FAIL to require the invariant?'
    resign
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'rejects a changed Choice rubric even when its request hash matches' do
    choice['criteria']['direct'] = 'Anything with an assertion is direct.'
    resign
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'rejects invalid UTF-8 strings through the in-memory interface' do
    entry['id'] = "bad\xFF".dup.force_encoding(Encoding::UTF_8)
    expect { replay }.to raise_error(WoodsDevelopment::TypeSafe::InvalidEvidence)
  end

  it 'returns sanitized exit 2 for invalid UTF-8 through the CLI' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'invalid.json')
      bytes = JSON.generate(document).sub('"id":"one"', '"id":"BAD"').b
      File.binwrite(path, bytes.sub('BAD', "bad\xFF".b))
      command = File.expand_path('../../../script/typesafe/cli.rb', __dir__)
      stdout, stderr, status = Open3.capture3('ruby', command, 'replay', path)
      expect(status.exitstatus).to eq(2)
      expect(stdout).to eq('')
      expect(stderr).to eq("Cannot replay: invalid or unreadable evidence\n")
    end
  end

  it 'keeps the developer tooling outside the packaged gem' do
    gemspec = Gem::Specification.load(File.expand_path('../../../woods.gemspec', __dir__))
    expect(gemspec.files.grep(%r{\A(?:script/typesafe|spec/development/typesafe)/})).to be_empty
  end
end
