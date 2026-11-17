# frozen_string_literal: true

# The fixture index under spec/fixtures/woods is read, and copied, by every
# spec process at once (script/parallel-rspec). A spec that writes it in
# place hands the others an empty or edited file for that moment: copy it
# into a temporary directory first. This fails the run that writes it.
module SharedFixtureGuard
  ROOT = File.expand_path('../fixtures/woods', __dir__)

  module_function

  # @return [Hash{String => Array}] each file's identity: a rewrite, even
  #   back to the same bytes, changes its inode or modification time
  def identities
    Dir.glob(File.join(ROOT, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h do |path|
      stat = File.stat(path)
      [path, [stat.ino, stat.mtime.to_r, stat.size]]
    end
  end
end

RSpec.configure do |config|
  before = nil
  config.before(:suite) { before = SharedFixtureGuard.identities }
  config.after(:suite) do
    after = SharedFixtureGuard.identities
    changed = (before.keys | after.keys).reject { |path| before[path] == after[path] }
    unless changed.empty?
      raise "A spec wrote the shared fixture index (#{SharedFixtureGuard::ROOT}); copy it first: " \
            "#{changed.map { |path| path.delete_prefix("#{SharedFixtureGuard::ROOT}/") }.join(', ')}"
    end
  end
end
