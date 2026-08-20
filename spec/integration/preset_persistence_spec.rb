# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/builder'

RSpec.describe 'Preset persistence contracts' do
  it 'reopens local preset metadata from a clean Ruby process' do
    Dir.mktmpdir('woods-preset-persistence') do |dir|
      config = Woods::Builder.preset_config(:local)
      config.output_dir = dir
      store = Woods::Builder.new(config).build_metadata_store
      store.store('User', type: 'model', file_path: 'app/models/user.rb')

      database = File.join(dir, 'metadata.sqlite3')
      script = <<~RUBY
        require 'json'
        require 'woods'
        require 'woods/storage/metadata_store'

        store = Woods::Storage::MetadataStore::SQLite.new(database: ARGV.fetch(0))
        print JSON.generate(store.find('User'))
      RUBY

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        '-I', File.expand_path('../../lib', __dir__),
        '-e', script,
        database
      )

      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to include(
        'type' => 'model',
        'file_path' => 'app/models/user.rb'
      )
    end
  end
end
