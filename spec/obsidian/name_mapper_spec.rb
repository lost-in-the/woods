# frozen_string_literal: true

require 'spec_helper'
require 'woods/obsidian/name_mapper'

RSpec.describe Woods::Obsidian::NameMapper do
  def mapper(id_to_dir)
    described_class.new(id_to_dir)
  end

  describe 'basic mapping' do
    it 'maps a plain identifier to <dir>/<id>.md' do
      m = mapper('User' => 'models')
      expect(m.path_for('User')).to eq('models/User.md')
      expect(m.wikilink('User')).to eq('[[models/User|User]]')
    end

    it 'sanitizes :: to __ in the filename but keeps it in the alias' do
      m = mapper('Users::RegistrationsController' => 'controllers')
      expect(m.path_for('Users::RegistrationsController'))
        .to eq('controllers/Users__RegistrationsController.md')
      expect(m.wikilink('Users::RegistrationsController'))
        .to eq('[[controllers/Users__RegistrationsController|Users::RegistrationsController]]')
    end

    it 'sanitizes a method-ref identifier so the link target never contains #' do
      m = mapper('Foo#create' => 'controllers')
      # alias keeps the readable form (# is safe in alias text); the target
      # half (before the `|`) must never contain #.
      expect(m.wikilink('Foo#create')).to eq('[[controllers/Foo_create|Foo#create]]')
    end

    it 'returns nil for unknown ids' do
      m = mapper('User' => 'models')
      expect(m.path_for('Nope')).to be_nil
      expect(m.wikilink('Nope')).to be_nil
    end
  end

  describe 'collisions' do
    it 'disambiguates two ids that sanitize to the same basename in one folder' do
      m = mapper('Foo::Bar' => 'models', 'Foo__Bar' => 'models')
      p1 = m.path_for('Foo::Bar')
      p2 = m.path_for('Foo__Bar')
      expect(p1).not_to eq(p2)
      expect([p1, p2]).to all(start_with('models/Foo__Bar'))
    end

    it 'treats a case-only difference as a collision on case-insensitive filesystems' do
      m = mapper('User' => 'models', 'user' => 'models')
      expect(m.path_for('User').downcase).not_to eq(m.path_for('user').downcase)
    end

    it 'does NOT disambiguate the same basename in different folders' do
      # Two distinct ids that sanitize to the same basename but live in
      # different type folders — different paths already, so no hash needed.
      m = mapper('Foo::Bar' => 'models', 'Foo__Bar' => 'policies')
      expect(m.path_for('Foo::Bar')).to eq('models/Foo__Bar.md')
      expect(m.path_for('Foo__Bar')).to eq('policies/Foo__Bar.md')
    end

    it 'reserves the MOC basename _index so a unit cannot overwrite a folder index' do
      m = mapper('_index' => 'models')
      expect(m.path_for('_index')).not_to eq('models/_index.md')
      expect(m.path_for('_index')).to start_with('models/_index-')
    end

    # EXP-9. The hashed candidate was inserted into the taken set without
    # being re-checked against it, so a hash prefix that happened to equal an
    # existing literal basename produced two ids at one path (last writer
    # wins) and dropped one of them from the inverse map.
    it 'keeps widening the hashed candidate until the basename is free' do
      allow(Digest::SHA256).to receive(:hexdigest).and_return('aaaaaaaa' * 8)

      m = mapper('Foo-aaaaaaaa' => 'models', 'Foo' => 'models', 'foo' => 'models')
      paths = %w[Foo-aaaaaaaa Foo foo].map { |id| m.path_for(id) }

      expect(paths.map(&:downcase).uniq.size).to eq(3)
      expect(m.paths_to_ids.size).to eq(3)
    end
  end

  # EXP-9. Windows cannot create a file named CON/PRN/AUX/NUL/COM1-9/LPT1-9
  # (with or without an extension), so a Ruby class named `Aux` broke any
  # vault synced through Windows or OneDrive.
  describe 'Windows reserved device names' do
    %w[CON PRN AUX NUL COM1 COM9 LPT1 LPT9].each do |device|
      it "does not emit a bare #{device} basename" do
        m = mapper(device => 'models')

        expect(File.basename(m.path_for(device), '.md').upcase).not_to eq(device)
      end
    end

    it 'sanitizes the lowercase and mixed-case spellings too' do
      m = mapper('aux' => 'models', 'Nul' => 'policies')

      expect(File.basename(m.path_for('aux'), '.md').upcase).not_to eq('AUX')
      expect(File.basename(m.path_for('Nul'), '.md').upcase).not_to eq('NUL')
    end

    it 'leaves names that merely start with a device name alone' do
      m = mapper('Console' => 'models', 'Auxiliary' => 'models')

      expect(m.path_for('Console')).to eq('models/Console.md')
      expect(m.path_for('Auxiliary')).to eq('models/Auxiliary.md')
    end
  end

  describe 'length safety' do
    it 'keeps filenames within 255 bytes and round-trips via the inverse map' do
      long_id = 'A' * 500
      m = mapper(long_id => 'models')
      path = m.path_for(long_id)
      basename = File.basename(path)
      expect(basename.bytesize).to be <= 255
      expect(m.paths_to_ids[path]).to eq(long_id)
    end

    it 'truncates multibyte ids on a character boundary within the byte budget' do
      multibyte_id = 'é' * 300
      m = mapper(multibyte_id => 'models')
      basename = File.basename(m.path_for(multibyte_id))
      expect(basename.bytesize).to be <= 255
      expect(basename).to be_valid_encoding
    end
  end

  describe 'inverse map + determinism' do
    it 'exposes a bijective path -> id inverse map' do
      input = { 'User' => 'models', 'Post' => 'models', 'Foo#create' => 'controllers' }
      m = mapper(input)
      input.each_key { |id| expect(m.paths_to_ids[m.path_for(id)]).to eq(id) }
      expect(m.paths_to_ids.size).to eq(input.size)
    end

    it 'produces identical output across builds (deterministic)' do
      input = { 'Foo::Bar' => 'models', 'Foo__Bar' => 'models', 'Zeta' => 'jobs' }
      expect(mapper(input).paths_to_ids).to eq(mapper(input).paths_to_ids)
    end
  end
end
