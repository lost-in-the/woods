# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'woods/extractor'

# A writer promotes its stage to payloads/gen-<n> before it writes the marker,
# so after a failed publish the newest retained directory never published.
# Every message about an unreadable marker gives the same advice.
RSpec.describe 'Restore advice for an unreadable generation marker' do
  include_context 'isolated Woods runtime'

  it 'refuses a writer with the shared advice, never pointing at the newest retained payload' do
    Dir.mktmpdir('woods_restore_advice') do |dir|
      File.write(File.join(dir, Woods::Generation::FILENAME), '{"number": ')
      extractor = Woods::Extractor.allocate
      extractor.instance_variable_set(:@output_dir, Pathname.new(dir))

      expect { extractor.send(:published_marker_for_write) }.to raise_error(Woods::ExtractionError) do |error|
        expect(error.message).to include('refusing to publish a new generation', Woods::Generation::RESTORE_ADVICE)
        expect(error.message).not_to include('newest retained')
      end
    end
  end

  it 'names the second newest as the safe choice and a fresh extraction when there is no evidence' do
    expect(Woods::Generation::RESTORE_ADVICE)
      .to include('except possibly the newest', 'second newest', 'extract afresh into a new output directory')
  end
end
