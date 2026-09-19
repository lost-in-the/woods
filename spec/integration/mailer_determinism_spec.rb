# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

RSpec.describe 'Mailer extraction across independent Rails processes', :booted_app do
  def extract_mailer(kind, publish: false)
    script = File.expand_path('../fixtures/mailer_determinism/boot.rb', __dir__)
    output, error, status = Open3.capture3({ 'MAILER_DEFAULT_KIND' => kind, 'MAILER_PUBLISH' => publish ? '1' : '0' },
                                           RbConfig.ruby, '-Ilib', script)
    expect(status.success?).to be(true), error
    JSON.parse(output.lines.last)
  end

  it 'preserves complete metadata, annotated source and chunks across boots and different application roots' do
    first = extract_mailer('lambda')
    expect(extract_mailer('lambda')).to eq(first)
    expect(first.dig('metadata', 'actions')).to eq(%w[alpha beta delta epsilon gamma zeta])
    expect(first.dig('metadata', 'defaults', 'from')).to start_with('#<lambda app/mailers/stable_mailer.rb:')
    expect(first.dig('metadata', 'defaults', 'cc')).to eq(['copy@example.test'])
    expect(first.dig('metadata', 'defaults', 'reply_to')).to eq('literal-0xdeadbeef@example.test')
    expect(first.dig('metadata', 'callbacks').map { |callback| callback['type'] })
      .to eq(%w[before_action before_action around_action after_action])
    expect(first.fetch('chunks').map { |chunk| chunk['identifier'] })
      .to eq(%w[alpha beta delta epsilon gamma zeta].map { |action| "StableMailer##{action}" })
    expect(first.dig('metadata', 'callbacks').first.fetch('filter')).to eq('#<StableMailer::ObjectCallback>')
    expect(JSON.generate(first)).not_to match(/:0x[0-9a-f]+>/i)
  end

  it 'retains meaningful callable kind changes without invoking defaults or callbacks' do
    first = extract_mailer('lambda')
    changed = extract_mailer('proc')
    expect(changed.dig('metadata', 'defaults', 'from')).to start_with('#<Proc app/mailers/stable_mailer.rb:')
    expect(changed.fetch('metadata')).not_to eq(first.fetch('metadata'))
    expect(changed.fetch('source_hash')).not_to eq(first.fetch('source_hash'))
  end

  it 'publishes equivalent full and incremental mailer records through MCP after an action edit' do
    result = extract_mailer('lambda', publish: true)
    expect(result.fetch('incremental')).to eq(result.fetch('full'))
    expect(result.dig('full', 'source_hash')).not_to eq(result.fetch('before_hash'))
    expect(result.dig('full', 'source_code')).to include('def alpha; :changed; end')
    chunk = result.dig('full', 'chunks').find { |item| item['identifier'] == 'StableMailer#alpha' }
    expect(chunk.fetch('content')).to include('def alpha; :changed; end')
    expect(result.dig('full', 'metadata', 'defaults', 'from')).to start_with('#<lambda app/mailers/stable_mailer.rb:')
    expect(result.dig('full', 'metadata', 'actions')).to eq(%w[alpha beta delta epsilon gamma zeta])
  end
end
