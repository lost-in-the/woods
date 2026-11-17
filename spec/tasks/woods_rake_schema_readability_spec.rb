# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/rake_helpers'

RSpec.describe 'Schema readability warning in the extraction task output' do
  def summary(state, databases = [])
    { 'version' => 1, 'state' => state, 'databases' => databases }
  end

  def warning_for(manifest)
    Dir.mktmpdir('woods-schema-warning') do |index|
      File.write(File.join(index, 'manifest.json'), JSON.generate(manifest)) if manifest
      Woods::RakeHelpers.woods_schema_readability_warning(index)
    end
  end

  it 'warns, naming the database and the fix, when the published schema could not be read' do
    warning = warning_for('schema_readability' => summary('unreadable', [{ 'name' => 'primary',
                                                                           'state' => 'empty' }]))

    expect(warning).to start_with('WARNING: The database schema could not be read')
    expect(warning).to include('primary: holds no tables', 'db:prepare')
  end

  it 'says nothing for a readable schema, an index that predates the record, or no manifest' do
    expect(warning_for('schema_readability' => summary('readable'))).to be_nil
    expect(warning_for('counts' => {})).to be_nil
    expect(warning_for(nil)).to be_nil
  end
end
