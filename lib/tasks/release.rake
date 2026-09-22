# frozen_string_literal: true

require_relative '../woods/release/preparer'
require_relative '../woods/release/rake_support'

namespace :release do
  desc 'Prepare the reviewed one-off 1.6.3 maintenance candidate without publishing'
  task :prepare, [:version] do |_task, args|
    Woods::Release::RakeSupport.run('release:prepare', args[:version]) do |root, version|
      Woods::Release::Preparer.prepare(root: root, version: version)
    end
  end

  desc 'Reopen 1.6.2 as 1.6.3.alpha without committing or tagging'
  task :reopen, [:version] do |_task, args|
    Woods::Release::RakeSupport.run('release:reopen', args[:version]) do |root, version|
      Woods::Release::Preparer.reopen(root: root, version: version)
    end
  end
end

%w[release release:rubygem_push release:source_control_push].each do |name|
  Woods::Release::RakeSupport.block_task(
    name, description: 'BLOCKED: maintenance publication belongs to the trusted main workflow',
          message: 'use release:reopen and release:prepare; only the maintainer may tag and dispatch after reviewed CI'
  )
end
