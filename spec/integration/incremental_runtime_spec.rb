# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'tmpdir'

RSpec.describe 'Incremental runtime discovery', :booted_app do
  it 'refreshes an unchanged nested job after an indirect Ruby input changes in a fresh task process' do
    Dir.mktmpdir('woods-hybrid-input') do |root|
      %w[before after].each_with_index do |phase, index|
        fixture = 'spec/fixtures/incremental_runtime/hybrid_task.rb'
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', fixture, root, phase)
        expect(status).to be_success, "#{stdout}\n#{stderr}"
        result = JSON.parse(stdout.lines.last)
        expect(result).to include('live' => phase, 'indexed' => phase, 'full' => phase, 'generation' => index + 1)
      end
    end
  end

  it 'preserves nested ActiveJob and AMS units through full, incremental and refresh publication' do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/incremental_runtime/boot.rb')
    expect(status).to be_success, "#{stdout}\n#{stderr}"
    result = JSON.parse(stdout.lines.last)
    expect(result.fetch('checks')).to include('nested jobs and serializers', 'runtime additions and removals',
                                              'full/incremental/refresh equivalence', 'resolved behavioral profile')
  end

  %w[db/schema.rb db/structure.sql config/application.rb config/initializers/runtime.rb].each do |input|
    %w[schema_only mixed].each do |phase|
      it "fully refreshes #{input} with #{phase} changes from a fresh task boot" do
        Dir.mktmpdir('woods-schema-task') do |root|
          %w[baseline].push(phase).each_with_index do |step, index|
            fixture = 'spec/fixtures/incremental_runtime/schema_task.rb'
            stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', fixture, root, step, input)
            expect(status).to be_success, "#{stdout}\n#{stderr}"
            expect(JSON.parse(stdout.lines.last).fetch('generation')).to eq(index + 1)
          end
        end
      end
    end
  end
end
