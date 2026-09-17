# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/change_set'
require 'woods/path_dispatcher'

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

    it 'dispatches changed files when the root ends with a slash' do
      set = described_class.new(paths: ['app/services/checkout.rb'], root: "#{root}/")

      expect(set.relative_paths).to eq(['app/services/checkout.rb'])
      expect(Woods::PathDispatcher.new.file_rules_for(set.relative_paths.first).map(&:extractor_key))
        .to include(:services)
    end

    it 'normalizes absolute and relative spellings before deduplicating and dispatching' do
      canonical = touch('app/services/checkout.rb')
      set = described_class.new(paths: ["#{root}/app//services/./checkout.rb",
                                        'app//services/checkout.rb', 'app/services/../services/checkout.rb'],
                                root: root)

      expect(set.absolute_paths).to eq([canonical])
      expect(set.existing_paths).to eq([canonical])
      expect(set.relative_paths).to eq(['app/services/checkout.rb'])
      expect(Woods::PathDispatcher.new.file_rules_for(set.relative_paths.first).map(&:extractor_key))
        .to include(:services)
    end

    it 'normalizes deleted paths without requiring filesystem resolution' do
      set = described_class.new(paths: ["#{root}/config//./routes.rb"], root: "#{root}//")

      expect(set.missing_paths).to eq([File.join(root, 'config/routes.rb')])
      expect(set.relative_paths).to eq(['config/routes.rb'])
      expect(Woods::PathDispatcher.new.whole_app_keys_for(set.relative_paths.first))
        .to include(:routes)
    end

    it 'resolves a relative root before constructing absolute paths' do
      relative_root = Pathname.new(root).relative_path_from(Pathname.pwd)
      set = described_class.new(paths: ['app/services/checkout.rb'], root: "#{relative_root}/")

      expect(set.root.to_s).to eq(root)
      expect(set.absolute_paths).to eq([File.join(root, 'app/services/checkout.rb')])
      expect(set.relative_paths).to eq(['app/services/checkout.rb'])
    end

    it 'relativizes paths under the filesystem root' do
      set = described_class.new(paths: ['/app//services/checkout.rb'], root: '/')
      expect(set.relative_paths).to eq(['app/services/checkout.rb'])
    end

    it 'keeps paths outside the root absolute after dot segment normalization' do
      set = described_class.new(paths: ["#{root}/../elsewhere/thing.rb", "#{root}-other/file.rb"], root: "#{root}/")
      expect(set.relative_paths).to eq([File.join(File.dirname(root), 'elsewhere/thing.rb'), "#{root}-other/file.rb"])
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
