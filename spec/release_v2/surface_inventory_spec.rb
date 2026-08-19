# frozen_string_literal: true

require 'spec_helper'
require 'rake'

RSpec.describe 'release-v2 public-surface inventory' do
  let(:rakefile) { File.expand_path('../../Rakefile', __dir__) }

  around do |example|
    previous = Rake.application
    Rake.application = Rake::Application.new
    example.run
  ensure
    Rake.application = previous
  end

  it 'provides a deterministic inventory verification task' do
    load rakefile

    expect(Rake::Task.task_defined?('release_v2:verify_surface_inventory')).to be(true)
    expect(Rake::Task['release_v2:verify_surface_inventory'].arg_names).to eq([])
    expect { Rake::Task['release_v2:verify_surface_inventory'].invoke }.not_to raise_error
  end
end
