# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'tmpdir'

RSpec.describe 'Library contributor publication', :booted_app do
  %w[unmanaged once].each do |loader|
    it "preserves #{loader} library contributors through full, incremental, refresh and deletion" do
      Dir.mktmpdir('woods-library-contributors') do |root|
        %w[baseline edit dependency refresh delete restore delete_primary failure].each do |phase|
          out, err, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/library_contributors/boot.rb', root,
                                            phase, loader)
          expect(status).to be_success, "#{phase}: #{out}\n#{err}"
          expect(JSON.parse(out.lines.last)).to include('phase' => phase, 'identifier' => 'LibraryFixture')
        end
      end
    end
  end
end
