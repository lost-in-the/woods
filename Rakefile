# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

# Load gem tasks that don't require Rails (self_analyze).
# Tasks with :environment dependency (extract, flow, etc.) only work in Rails apps via Railtie.
load File.expand_path('lib/tasks/codebase_index.rake', __dir__)

task default: :spec
