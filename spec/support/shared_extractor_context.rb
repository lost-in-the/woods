# frozen_string_literal: true

RSpec.shared_context 'extractor setup' do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:rails_root) { Pathname.new(tmp_dir) }
  let(:logger) { double('Logger', error: nil, warn: nil, debug: nil, info: nil) }

  before do
    stub_const('Rails', double('Rails', root: rails_root, logger: logger))
    stub_const('CodebaseIndex::ModelNameCache', double('ModelNameCache', model_names_regex: /(?!)/))
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  def create_file(relative_path, content)
    full_path = File.join(tmp_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    full_path
  end
end
