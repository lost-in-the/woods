# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'Maintenance task publication guards' do
  %w[release release:rubygem_push release:source_control_push].each do |task|
    it "blocks #{task} before its old actions or prerequisites can run" do
      source = <<~RUBY
        require 'rake'
        task(:dangerous) { abort 'PUBLISH ACTION RAN' }
        task('#{task}' => :dangerous) { abort 'PUBLISH ACTION RAN' }
        load #{File.expand_path('../../lib/tasks/release.rake', __dir__).inspect}
        Rake::Task['#{task}'].invoke
      RUBY
      output, status = Open3.capture2e(Gem.ruby, '-e', source)
      expect(status).not_to be_success
      expect(output).to include("#{task} is blocked")
      expect(output).not_to include('PUBLISH ACTION RAN')
    end
  end
end
