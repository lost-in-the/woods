# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/preparer'

RSpec.describe 'Retargeting unpublished alpha development' do
  it 'moves to the next minor alpha without folding notes or creating tags' do
    with_release_repository(version: '2.0.1.alpha') do |root|
      changelog = release_file(root, 'CHANGELOG.md')
      result = Woods::Release::Preparer.retarget(root: root, version: '2.1.0.alpha')
      expect(read_release_version(root)).to eq('2.1.0.alpha')
      expect(release_file(root, 'CHANGELOG.md')).to eq(changelog)
      expect(release_git(root, 'tag', '--list')).to eq('')
      expect(result.report).to include('Retargeted development', '2.1.0.alpha')
      expect(release_file(root, 'README.md')).to include('main` documents 2.1.0')
    end
  end

  %w[2.0.1 2.0.1.beta1 2.0.1.rc1].each do |tag|
    it "refuses when the current line already has tag #{tag}" do
      with_release_repository(version: '2.0.1.alpha') do |root|
        release_git(root, 'tag', "v#{tag}")
        before = release_repository_digest(root)
        expect { Woods::Release::Preparer.retarget(root: root, version: '2.1.0.alpha') }
          .to raise_error(Woods::Release::VersionState::InvalidTransition, /already has release tags/)
        expect(release_repository_digest(root)).to eq(before)
      end
    end
  end

  it 'refuses a tagged target line without changing files' do
    with_release_repository(version: '2.0.1.alpha') do |root|
      release_git(root, 'tag', 'v2.1.0.beta1')
      before = release_repository_digest(root)
      expect { Woods::Release::Preparer.retarget(root: root, version: '2.1.0.alpha') }
        .to raise_error(Woods::Release::VersionState::InvalidTransition, /already has release tags/)
      expect(release_repository_digest(root)).to eq(before)
    end
  end

  it 'refuses dirty trees without changing files' do
    with_release_repository(version: '2.0.1.alpha') do |root|
      File.write(File.join(root, 'uncommitted.txt'), 'preserve me')
      before = release_repository_digest(root)
      expect { Woods::Release::Preparer.retarget(root: root, version: '2.1.0.alpha') }
        .to raise_error(Woods::Release::Preparer::DirtyWorkingTree)
      expect(release_repository_digest(root)).to eq(before)
    end
  end

  [['2.0.1.alpha', '2.0.2.alpha'], ['2.0.1.alpha', '3.0.0.alpha'],
   ['2.0.1.alpha', '2.1.1.alpha'], ['2.0.1.alpha', '2.1.0'],
   ['2.0.1.beta1', '2.1.0.alpha'], ['2.0.1', '2.1.0.alpha']].each do |current, target|
    it "refuses #{current} to #{target} without changing files" do
      with_release_repository(version: current) do |root|
        before = release_repository_digest(root)
        expect { Woods::Release::Preparer.retarget(root: root, version: target) }
          .to raise_error(Woods::Release::VersionState::InvalidTransition)
        expect(release_repository_digest(root)).to eq(before)
      end
    end
  end
end
