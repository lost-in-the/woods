# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Extractor symlink caches across runs' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-symlink-cache') do |dir|
      @root = Pathname.new(File.realpath(dir))
      example.run
    end
  end

  let(:extractor) { Woods::Extractor.new(output_dir: @root.join('index')) }
  let(:source) { @root.join('app/models/real/a.rb').to_s }
  let(:elsewhere) { @root.join('elsewhere/real') }

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object))
    FileUtils.mkdir_p(@root.join('app/models/real'))
    FileUtils.mkdir_p(elsewhere)
    File.write(source, '')
    File.write(elsewhere.join('a.rb'), '')
    allow(Woods::ModelNameCache).to receive(:reset!)
    allow(extractor).to receive_messages(setup_output_directory: nil, begin_source_inputs: nil,
                                         begin_payload!: nil, ensure_supported_incremental_writer!: {},
                                         baseline_extraction_config: nil, ensure_incremental_baseline!: nil,
                                         prepare_source_reference_baseline: nil)
  end

  def start_run(kind)
    if kind == 'full'
      allow(extractor).to receive(:safe_eager_load!).and_raise(StopIteration)
      extractor.extract_all
    else
      allow(extractor).to receive(:safe_eager_load!)
      extractor.send(:prepare_incremental_run)
    end
  rescue StopIteration
    nil
  end

  def replace_directory_with_symlink
    FileUtils.rm_rf(@root.join('app/models/real'))
    File.symlink(elsewhere.to_s, @root.join('app/models/real').to_s)
  end

  %w[full incremental].each do |kind|
    it "sees a directory that became a symlink after a #{kind} run starts" do
      extractor.send(:path_spellings, source)
      replace_directory_with_symlink
      start_run(kind)

      expect(extractor.send(:path_spellings, source))
        .to eq(Woods::Extractor.new(output_dir: @root.join('index')).send(:path_spellings, source))
    end
  end
end
