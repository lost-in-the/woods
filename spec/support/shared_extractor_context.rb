# frozen_string_literal: true

require 'pathname'

RSpec.shared_context 'extractor setup' do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:rails_root) { Pathname.new(tmp_dir) }
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }

  before do
    @_real_model_name_cache = CodebaseIndex::ModelNameCache
    stub_const('Rails', double('Rails', root: rails_root, logger: logger))
    stub_const('CodebaseIndex::ModelNameCache', double('ModelNameCache', model_names_regex: /(?!)/, reset!: nil))
  end

  after do
    FileUtils.rm_rf(tmp_dir)
    @_real_model_name_cache.reset!
  end

  def create_file(relative_path, content)
    full_path = File.join(tmp_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    full_path
  end
end
