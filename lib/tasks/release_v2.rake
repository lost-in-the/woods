# frozen_string_literal: true

require_relative '../woods/release_v2/surface_inventory'

namespace :release_v2 do
  desc 'Write the code-derived release-v2 public-surface inventory'
  task :write_surface_inventory do
    Woods::ReleaseV2::SurfaceInventory.write!
  end

  desc 'Fail when the checked-in release-v2 public-surface inventory drifts from code'
  task :verify_surface_inventory do
    Woods::ReleaseV2::SurfaceInventory.verify!
  end
end
