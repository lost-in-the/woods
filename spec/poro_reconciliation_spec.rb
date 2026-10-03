# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'woods/poro_reconciliation'

RSpec.describe Woods::PoroReconciliation do
  let(:host) { Class.new { include Woods::PoroReconciliation }.new }
  let(:scratch) { File.realpath(Dir.mktmpdir('woods_spellings')) }

  after { FileUtils.rm_rf(scratch) }

  def spellings(path)
    host.send(:path_spellings, path)
  end

  def write(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# source\n")
    path
  end

  context 'when nothing between the filesystem root and the file is a symlink' do
    let(:root) { File.join(scratch, 'app_root') }

    before { stub_const('Rails', double('Rails', root: Pathname.new(root))) }

    it 'calls File.realpath once for the root, however many paths it is asked about' do
      paths = Array.new(200) { |index| write(File.join(root, "app/models/m#{index % 20}/unit_#{index}.rb")) }
      allow(File).to receive(:realpath).and_call_original

      paths.each { |path| expect(spellings(path)).to eq([path]) }
      expect(File).to have_received(:realpath).at_most(:once)
    end

    it 'still resolves a file reached through a symlinked directory under the root' do
      real = write(File.join(scratch, 'shared/lib/ledger.rb'))
      FileUtils.mkdir_p(File.join(root, 'app'))
      File.symlink(File.join(scratch, 'shared/lib'), File.join(root, 'app/lib'))

      linked = File.join(root, 'app/lib/ledger.rb')
      expect(spellings(linked)).to eq([linked, real])
    end
  end

  context 'when the root itself is a symlink' do
    let(:real_root) { File.join(scratch, 'real_root') }
    let(:root) { File.join(scratch, 'linked_root') }

    before do
      FileUtils.mkdir_p(real_root)
      File.symlink(real_root, root)
      stub_const('Rails', double('Rails', root: Pathname.new(root)))
    end

    it 'resolves both spellings' do
      write(File.join(real_root, 'app/models/widget.rb'))

      expect(spellings(File.join(root, 'app/models/widget.rb')))
        .to eq([File.join(root, 'app/models/widget.rb'), File.join(real_root, 'app/models/widget.rb')])
    end
  end
end
