# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/change_set'

RSpec.describe Woods::ChangeSet do
  let(:root) { Dir.mktmpdir('woods_change_set') }

  after { FileUtils.rm_rf(root) }

  def touch(relative)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    path
  end

  describe 'path normalization' do
    it 'absolutizes relative paths against the root' do
      set = described_class.new(paths: ['app/models/user.rb'], root: root)

      expect(set.absolute_paths).to eq([File.join(root, 'app/models/user.rb')])
    end

    it 'leaves already-absolute paths alone' do
      absolute = File.join(root, 'app/models/user.rb')
      set = described_class.new(paths: [absolute], root: root)

      expect(set.absolute_paths).to eq([absolute])
    end

    it 'de-duplicates paths given in both forms' do
      set = described_class.new(
        paths: ['app/models/user.rb', File.join(root, 'app/models/user.rb')],
        root: root
      )

      expect(set.absolute_paths.size).to eq(1)
    end

    it 'drops blank entries from a trailing newline in a git diff' do
      set = described_class.new(paths: ['app/models/user.rb', '', '  '], root: root)

      expect(set.size).to eq(1)
    end

    it 'exposes root-relative paths for rule matching' do
      set = described_class.new(paths: [File.join(root, 'app/models/user.rb')], root: root)

      expect(set.relative_paths).to eq(['app/models/user.rb'])
    end

    it 'leaves paths outside the root unchanged when relativizing' do
      set = described_class.new(paths: ['/elsewhere/thing.rb'], root: root)

      expect(set.relative_paths).to eq(['/elsewhere/thing.rb'])
    end
  end

  describe 'existing vs vanished' do
    it 'splits paths by whether they are still on disk' do
      present = touch('app/models/user.rb')
      set = described_class.new(paths: ['app/models/user.rb', 'app/models/gone.rb'], root: root)

      expect(set.existing_paths).to eq([present])
      expect(set.missing_paths).to eq([File.join(root, 'app/models/gone.rb')])
    end

    it 'reports empty for an empty change set' do
      expect(described_class.new(paths: [], root: root)).to be_empty
    end
  end
end
