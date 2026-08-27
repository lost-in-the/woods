# frozen_string_literal: true

require 'spec_helper'
require 'open3'

# `woods_payload_dir` names Woods::Generation, which only `woods/extractor`
# required. A host app's `woods:clean` or `woods:validate` runs before any
# task has loaded the extractor, so the helper raised NameError there (seen
# on every woods-testbed variant). Proven in a subprocess: the in-process
# suite has already loaded the extractor and cannot see the gap.
RSpec.describe 'lib/tasks/woods.rake constant availability' do
  it 'resolves the payload directory after `require "woods"` alone' do
    root = File.expand_path('../..', __dir__)
    script = <<~RUBY
      require 'rake'
      require 'woods'
      load File.join(#{root.inspect}, 'lib/tasks/woods.rake')
      print woods_payload_dir(Dir.tmpdir).to_s
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.join(root, 'lib'), '-e', script)

    expect(status.success?).to be(true), "expected success, got: #{err}"
    expect(out).to eq(Dir.tmpdir)
  end
end
