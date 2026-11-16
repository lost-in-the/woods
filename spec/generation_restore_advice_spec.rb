# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'woods/extractor'

# A writer promotes its stage to payloads/gen-<n> before it writes the marker,
# so a retained directory may never have published. Every message about an
# unreadable marker gives the same advice.
RSpec.describe 'Restore advice for an unreadable generation marker' do
  include_context 'isolated Woods runtime'

  it 'refuses a writer with the shared advice' do
    Dir.mktmpdir('woods_restore_advice') do |dir|
      File.write(File.join(dir, Woods::Generation::FILENAME), '{"number": ')
      extractor = Woods::Extractor.allocate
      extractor.instance_variable_set(:@output_dir, Pathname.new(dir))

      expect { extractor.send(:published_marker_for_write) }.to raise_error(Woods::ExtractionError) do |error|
        expect(error.message).to include('refusing to publish a new generation', Woods::Generation::RESTORE_ADVICE)
      end
    end
  end

  # Directory order is not evidence: a failed publish, a flat-fallback run
  # and a later failed promotion can leave several unpublished gen-<n> behind.
  it 'names no directory by its position among the retained payloads' do
    expect(Woods::Generation::RESTORE_ADVICE).not_to match(/newest|oldest|latest|second|previous|highest/i)
  end

  it 'restores only to independent evidence of publication, and otherwise extracts into a fresh directory' do
    expect(Woods::Generation::RESTORE_ADVICE)
      .to include('independently known to have been published', 'backup of generation.json',
                  'keep the old output directory as it is', 'fresh output directory')
  end
end
