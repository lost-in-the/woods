# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

RSpec.describe 'Model validation options across Rails processes', :booted_app do
  def extract_validations(publish: false)
    script = File.expand_path('../fixtures/validation_options/boot.rb', __dir__)
    output, error, status = Open3.capture3({ 'VALIDATION_PUBLISH' => publish ? '1' : '0' },
                                           RbConfig.ruby, '-Ilib', script)
    expect(status.success?).to be(true), error
    JSON.parse(output.lines.last)
  end

  def check_options(unit)
    expected = [
      a_hash_including('type' => 'inclusion', 'conditions' => { 'unless' => ['Proc'] },
                       'options' => { 'in' => start_with('#<lambda app/models/validation_item.rb:') }),
      a_hash_including('type' => 'exclusion', 'conditions' => { 'on' => 'update' },
                       'options' => { 'in' => start_with('#<Proc app/models/validation_item.rb:') }),
      a_hash_including('type' => 'presence', 'conditions' => { 'if' => [':ready?'] },
                       'options' => { 'message' => start_with('#<Proc app/models/validation_item.rb:') }),
      a_hash_including('type' => 'inclusion', 'conditions' => {},
                       'options' => { 'in' => %w[ready pending], 'message' => 'literal 0xdeadbeef',
                                      'allow_nil' => true })
    ]
    expect(unit.fetch('metadata').fetch('validations')).to match(expected)
  end

  it 'preserves complete units across independent boots and roots without executing validators or conditions' do
    first = extract_validations
    expect(extract_validations).to eq(first)
    check_options(first)
  end

  it 'publishes matching full and incremental records through MCP after a model edit' do
    first = extract_validations(publish: true)
    expect(first.fetch('incremental')).to eq(first.fetch('full'))
    expect(first.dig('full', 'source_hash')).not_to eq(first.fetch('before_hash'))
    expect(first.dig('full', 'source_code')).to include("'changed'")
    check_options(first.fetch('full'))
    expect(extract_validations(publish: true)).to eq(first)
  end
end
