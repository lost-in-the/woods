# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'pathname'
require 'stringio'
require 'tmpdir'
require 'woods'
require 'woods/extractor'
require 'woods/rake_helpers'

# `git diff HEAD~1` says what the last commit and the working tree changed,
# not what the index holds. A file extracted and then reverted leaves the diff
# while the index still carries the edit, and every later incremental run
# refused with a source-reference rebuild error; an untracked new file never
# entered the diff at all. The published source manifest knows which files no
# longer match, so the default change set adds them.
RSpec.describe 'woods:incremental change set and index drift' do
  let(:root) { Dir.mktmpdir('woods-drift-root') }
  let(:index) { File.join(root, 'tmp', 'woods') }
  let(:model) { File.join(root, 'app/models/order.rb') }
  let(:other) { File.join(root, 'app/models/invoice.rb') }

  def git(*args)
    out, status = Open3.capture2e('git', *args, chdir: root)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
  end

  def publish
    extractor = Woods::Extractor.new(output_dir: index)
    extractor.send(:begin_source_inputs, 'full')
    extractor.send(:begin_payload!)
    extractor.instance_variable_set(:@eager_load_complete, true)
    extractor.send(:publish_generation, 'full')
  end

  # Written after the capture second, as an edit made later is.
  def write_later(path, content)
    File.write(path, content)
    later = Time.now + 5
    File.utime(later, later, path)
  end

  def changed_paths
    original = $stdout
    $stdout = StringIO.new
    Woods::RakeHelpers.woods_incremental_changed_paths(index)
  ensure
    $stdout = original
  end

  around do |example|
    saved = %w[CHANGED_FILES CI_COMMIT_BEFORE_SHA CI_COMMIT_SHA GITHUB_BASE_REF].to_h do |name|
      [name, ENV.delete(name)]
    end
    example.run
  ensure
    saved.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    FileUtils.rm_rf(root)
  end

  before do
    stub_const('Rails', double(root: Pathname.new(root), logger: double.as_null_object))
    FileUtils.mkdir_p(File.dirname(model))
    File.write(model, "class Order\nend\n")
    File.write(other, "class Invoice\nend\n")
    File.write(File.join(root, '.gitignore'), "tmp/\n")
    git('init', '--quiet', '--initial-branch', 'main')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Test')
    git('config', 'commit.gpgsign', 'false')
    git('add', '-A')
    git('commit', '--quiet', '-m', 'first')
    File.write(File.join(root, 'README.md'), "notes\n")
    git('add', '-A')
    git('commit', '--quiet', '-m', 'second')
    earlier = Time.now - 100
    Dir[File.join(root, '**', '*')].each { |path| File.utime(earlier, earlier, path) if File.file?(path) }
  end

  it 'adds a file whose edit was extracted and then reverted' do
    File.write(model, "class Order\n  # edited\nend\n")
    publish
    git('checkout', '--quiet', '--', 'app/models/order.rb')
    later = Time.now + 5
    File.utime(later, later, model)

    expect(changed_paths).to include('app/models/order.rb')
  end

  it 'adds a new file that git does not track yet' do
    publish
    write_later(File.join(root, 'app/models/widget.rb'), "class Widget\nend\n")

    expect(changed_paths).to include('app/models/widget.rb')
  end

  it 'says how many files it added' do
    publish
    write_later(File.join(root, 'app/models/widget.rb'), "class Widget\nend\n")

    expect { Woods::RakeHelpers.woods_incremental_changed_paths(index) }
      .to output(/1 more file\(s\) differ from the index and are not in `git diff HEAD~1`/).to_stdout
  end

  it 'leaves out a file that was only touched' do
    publish
    later = Time.now + 5
    File.utime(later, later, other)

    expect(changed_paths).to eq(['README.md'])
  end

  it 'names a file once when the git range already reports it' do
    publish
    write_later(model, "class Order\n  # working-tree edit\nend\n")

    expect(changed_paths.count('app/models/order.rb')).to eq(1)
  end

  it 'uses the git range alone when nothing has been published' do
    write_later(File.join(root, 'app/models/widget.rb'), "class Widget\nend\n")

    expect(changed_paths).to eq(['README.md'])
  end

  it 'leaves an explicit CHANGED_FILES list as given' do
    publish
    write_later(File.join(root, 'app/models/widget.rb'), "class Widget\nend\n")
    ENV['CHANGED_FILES'] = 'app/models/invoice.rb'

    expect(changed_paths).to eq(['app/models/invoice.rb'])
  end

  it 'leaves a CI range as the range reports it' do
    publish
    write_later(File.join(root, 'app/models/widget.rb'), "class Widget\nend\n")
    ENV['CI_COMMIT_BEFORE_SHA'] = 'HEAD~1'
    ENV['CI_COMMIT_SHA'] = 'HEAD'

    expect(changed_paths).to eq(['README.md'])
  end

  it 'falls back to the git range when the comparison fails' do
    publish
    require 'woods/watch/catch_up'
    allow(Woods::Watch::CatchUp).to receive(:new).and_raise(IOError, 'unreadable')

    paths = nil
    expect { paths = Woods::RakeHelpers.woods_incremental_changed_paths(index) }
      .to output(/could not compare the working tree with the index \(IOError: unreadable\)/).to_stderr
    expect(paths).to eq(['README.md'])
  end
end
