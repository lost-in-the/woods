# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'Woods rake helper isolation' do
  it 'loads tasks without defining Object helpers and invokes a task despite a colliding host helper' do
    rake_path = File.expand_path('../../lib/tasks/woods.rake', __dir__)
    script = <<~RUBY_SCRIPT
      require 'rake'
      require 'delegate'
      require 'woods'
      before = Object.private_instance_methods(false)
      load #{rake_path.inspect}
      added = Object.private_instance_methods(false) - before
      abort "Object helpers leaked: \#{added.inspect}" unless added.empty?

      def woods_run_retrieval(*)
        raise 'host application helper must not be called'
      end

      Woods.configure do |config|
        config.embedding_provider = :fake
        config.vector_store = :in_memory
        config.metadata_store = :in_memory
        config.graph_store = :in_memory
      end
      Rake::Task.define_task(:environment)
      Rake::Task['woods:retrieve'].invoke('How does authentication work?')
    RUBY_SCRIPT

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script
    )

    expect(status.success?).to be(true), "stdout: #{stdout}\nstderr: #{stderr}"
    expect(stdout).to include('Codebase Context')
  end
end
