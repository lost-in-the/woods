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

  # A saved marker proves what was published then, not what the directory
  # holds now: after the number goes backward, a writer replaces the unpinned
  # gen-<n> it names before its own marker write, and may fail in between.
  it 'restores only from a backup of the marker together with the payload it names' do
    expect(Woods::Generation::RESTORE_ADVICE)
      .to include('complete backup of generation.json and the payloads/gen-<n> it names',
                  'keep the old output directory as it is', 'fresh output directory')
  end

  it 'does not accept a saved marker or a served identity on its own' do
    expect(Woods::Generation::RESTORE_ADVICE).not_to match(/served identity|independently known/)
  end
end
