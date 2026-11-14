# frozen_string_literal: true

require 'spec_helper'
require 'woods/git_history'
require 'tmpdir'
require 'fileutils'
require 'stringio'

RSpec.describe Woods::GitHistory do
  let(:root) { Dir.mktmpdir('woods_git_events') }
  let(:logger) { double('Logger').as_null_object }
  let(:reader) { described_class.new(root: root, logger: logger) }

  def git(*args, env: {})
    output, status = Open3.capture2e(env, 'git', '-C', root, *args)
    raise output unless status.success?

    output.strip
  end

  def commit(message, changes, days_ago: 0, author: 'Author')
    changes.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
    git('add', '-A')
    date = (Time.now - (days_ago * 86_400)).iso8601
    git('commit', '-qm', message, env: { 'GIT_AUTHOR_DATE' => date, 'GIT_COMMITTER_DATE' => date,
                                         'GIT_AUTHOR_NAME' => author })
  end

  def read(*paths)
    reader.read(paths, recent_after: Time.now - (90 * 86_400))
  end

  before do
    git('init', '-qb', 'main')
    git('config', 'user.name', 'Author')
    git('config', 'user.email', 'test@example.invalid')
  end

  after { FileUtils.rm_rf(root) }

  it 'preserves literal filenames and commit fields without delimiter collisions' do
    names = [' leading trailing ', "tab\tfile", "line\nfile", '__COMMIT__name', ':raw-like', 'café.rb', 'a' * 40]
    commit('subject ||| __COMMIT__ delimiters', names.to_h { |name| [name, 'a'] }, author: 'Åuthor ||| Name')

    result = read(*names)
    expect(result.keys).to eq(names)
    result.each_value do |data|
      expect(data[:commit_count]).to eq(1)
      expect(data[:commits].first).to include(message: 'subject ||| __COMMIT__ delimiters', author: 'Åuthor ||| Name')
    end
  end

  it 'counts HEAD-reachable side commits through an ours merge independently of requested paths' do
    commit('root', { 'target.rb' => 'base', 'other.rb' => 'base' })
    git('checkout', '-qb', 'side')
    commit('side change', { 'target.rb' => 'side' })
    git('checkout', '-q', 'main')
    commit('main change', { 'other.rb' => 'main' })
    git('merge', '-s', 'ours', '--no-ff', '-qm', 'discard side', 'side')

    single = read('target.rb').fetch('target.rb')
    expect(single).to eq(read('target.rb', 'other.rb').fetch('target.rb'))
    expect(single[:commits].map { |entry| entry[:message] }).to contain_exactly('root', 'side change')
  end

  it 'walks a supplied commit even after HEAD advances' do
    commit('original', { 'target.rb' => 'original' })
    captured_head = git('rev-parse', 'HEAD')
    commit('later', { 'target.rb' => 'later' })

    result = reader.read(['target.rb'], recent_after: Time.now - 86_400, revision: captured_head)

    expect(result.fetch('target.rb')[:commit_count]).to eq(1)
    expect(result.fetch('target.rb')[:commits].map { |entry| entry[:sha] }).to eq([captured_head])
  end

  it 'counts an ordinary merge introduction and its side commit as separate events' do
    commit('root', { 'target.rb' => 'base' })
    git('checkout', '-qb', 'side')
    commit('side change', { 'target.rb' => 'side' })
    git('checkout', '-q', 'main')
    git('merge', '--no-ff', '-qm', 'introduce side', 'side')

    expect(read('target.rb').fetch('target.rb')[:commits].map { |entry| entry[:message] })
      .to contain_exactly('root', 'side change', 'introduce side')
  end

  it 'counts a conflict-resolution merge once against its first parent plus both ancestors' do
    commit('root', { 'target.rb' => "base\n" })
    git('checkout', '-qb', 'side')
    commit('side change', { 'target.rb' => "side\n" })
    git('checkout', '-q', 'main')
    commit('main change', { 'target.rb' => "main\n" })
    _output, status = Open3.capture2e('git', '-C', root, 'merge', '--no-ff', 'side')
    expect(status.success?).to be(false)
    commit('resolution', { 'target.rb' => "resolved\n" })

    expect(read('target.rb').fetch('target.rb')[:commits].map { |entry| entry[:message] })
      .to contain_exactly('root', 'side change', 'main change', 'resolution')
  end

  it 'treats a rename as a deletion and addition without following the old name' do
    commit('old root', { 'old.rb' => 'same' })
    git('mv', 'old.rb', 'new.rb')
    git('commit', '-qm', 'rename')

    expect(read('new.rb').fetch('new.rb')[:commits].map { |entry| entry[:message] }).to eq(['rename'])
  end

  describe 'whether the window holds the commit that created a file' do
    it 'marks a file created inside the window' do
      commit('create', { 'fresh.rb' => 'one' }, days_ago: 20)
      commit('edit', { 'fresh.rb' => 'two' })

      expect(read('fresh.rb').fetch('fresh.rb')).to include(added: true, commit_count: 2)
    end

    it 'leaves an older file edited inside the window unmarked' do
      commit('create', { 'old.rb' => 'one' }, days_ago: 800)
      commit('edit', { 'old.rb' => 'two' }, days_ago: 3)

      facts = read('old.rb').fetch('old.rb')

      expect(facts).to include(commit_count: 1)
      expect(facts).not_to have_key(:added)
    end

    it 'reports nothing for an older file the window never touches' do
      commit('create', { 'quiet.rb' => 'one' }, days_ago: 800)
      commit('other', { 'other.rb' => 'x' })

      expect(read('quiet.rb').fetch('quiet.rb')).to eq({})
    end

    it 'marks a file recreated at its name inside the window' do
      commit('create', { 'gone.rb' => 'one' }, days_ago: 800)
      git('rm', '-q', 'gone.rb')
      git('commit', '-qm', 'remove')
      commit('recreate', { 'gone.rb' => 'two' })

      expect(read('gone.rb').fetch('gone.rb')).to include(added: true)
    end

    describe 'a file renamed inside the window (its content first appeared where it came from)' do
      let(:body) { (1..40).map { |line| "line #{line}\n" }.join }

      it 'leaves a file moved unchanged from an older file unmarked' do
        commit('create', { 'before.rb' => body }, days_ago: 800)
        git('mv', 'before.rb', 'after.rb')
        git('commit', '-qm', 'rename')

        facts = read('after.rb').fetch('after.rb')
        expect(facts).to include(commit_count: 1)
        expect(facts).not_to have_key(:added)
      end

      it 'leaves a file moved and edited in the same commit unmarked' do
        commit('create', { 'before.rb' => body }, days_ago: 800)
        git('rm', '-q', 'before.rb')
        commit('rename and edit', { 'after.rb' => "#{body}line 41\n" })

        expect(read('after.rb').fetch('after.rb')).not_to have_key(:added)
      end

      it 'follows renames back to an older file' do
        commit('create', { 'first.rb' => body }, days_ago: 800)
        git('mv', 'first.rb', 'second.rb')
        commit('rename once', {}, days_ago: 100)
        git('mv', 'second.rb', 'third.rb')
        commit('rename twice', {}, days_ago: 3)

        expect(read('third.rb').fetch('third.rb')).not_to have_key(:added)
      end

      it 'marks a file created inside the window and renamed after' do
        commit('create', { 'draft.rb' => body }, days_ago: 100)
        git('mv', 'draft.rb', 'final.rb')
        commit('rename', {}, days_ago: 3)

        expect(read('final.rb').fetch('final.rb')).to include(added: true, commit_count: 1)
      end

      it 'marks a new file added in a commit that deletes an unrelated one' do
        commit('create', { 'old.rb' => body }, days_ago: 800)
        git('rm', '-q', 'old.rb')
        commit('replace', { 'fresh.rb' => "class Fresh\n  def different; end\nend\n" })

        expect(read('fresh.rb').fetch('fresh.rb')).to include(added: true)
      end

      def rename(from, to, days_ago:)
        git('mv', from, to)
        commit("rename #{from}", {}, days_ago: days_ago)
      end

      def chain(length)
        commit('create', { 'name_0.rb' => body }, days_ago: 800)
        length.times { |step| rename("name_#{step}.rb", "name_#{step + 1}.rb", days_ago: 300 - step) }
        "name_#{length}.rb"
      end

      it 'follows a chain of three renames back to an older file' do
        name = chain(3)

        expect(read(name).fetch(name)).not_to have_key(:added)
      end

      it 'follows as many renames as RENAME_DEPTH' do
        name = chain(described_class::RENAME_DEPTH)

        expect(read(name).fetch(name)).not_to have_key(:added)
      end

      it 'keeps the mark on a file renamed more times than RENAME_DEPTH' do
        name = chain(described_class::RENAME_DEPTH + 1)

        expect(read(name).fetch(name)).to include(added: true, commit_count: 1)
      end

      describe 'the source is looked up only in the history of the rename (its first parent)' do
        it 'ignores a recreation of the source on a side branch merged with ours' do
          commit('create', { 'source.rb' => body }, days_ago: 800)
          git('checkout', '-qb', 'side')
          git('rm', '-q', 'source.rb')
          commit('delete on side', {}, days_ago: 200)
          commit('recreate on side', { 'source.rb' => "class Source\n  def other; end\nend\n" }, days_ago: 150)
          git('checkout', '-q', 'main')
          rename('source.rb', 'destination.rb', days_ago: 100)
          git('merge', '-s', 'ours', '--no-ff', '-qm', 'discard side', 'side')

          expect(read('destination.rb').fetch('destination.rb')).not_to have_key(:added)
        end

        it 'ignores a creation of the destination on a side branch merged with ours' do
          commit('create', { 'source.rb' => body }, days_ago: 800)
          git('checkout', '-qb', 'side')
          commit('create on side', { 'destination.rb' => "class Destination\nend\n" }, days_ago: 20)
          git('rm', '-q', 'destination.rb')
          commit('delete on side', {}, days_ago: 10)
          git('checkout', '-q', 'main')
          rename('source.rb', 'destination.rb', days_ago: 100)
          git('merge', '-s', 'ours', '--no-ff', '-qm', 'discard side', 'side')

          expect(read('destination.rb').fetch('destination.rb')).not_to have_key(:added)
        end

        it 'follows a rename a merge makes against its first parent' do
          commit('create', { 'before.rb' => body }, days_ago: 800)
          git('checkout', '-qb', 'side')
          rename('before.rb', 'after.rb', days_ago: 30)
          git('checkout', '-q', 'main')
          commit('unrelated', { 'other.rb' => 'x' }, days_ago: 20)
          git('merge', '--no-ff', '-qm', 'introduce side', 'side')

          expect(read('after.rb').fetch('after.rb')).not_to have_key(:added)
        end

        it 'marks a file created on a side branch and merged' do
          commit('root', { 'other.rb' => 'x' }, days_ago: 800)
          git('checkout', '-qb', 'side')
          commit('create on side', { 'fresh.rb' => body }, days_ago: 20)
          git('checkout', '-q', 'main')
          commit('unrelated', { 'other.rb' => 'y' }, days_ago: 10)
          git('merge', '--no-ff', '-qm', 'introduce side', 'side')

          expect(read('fresh.rb').fetch('fresh.rb')).to include(added: true, commit_count: 2)
        end

        it 'marks a file a merge creates that neither parent holds' do
          commit('root', { 'other.rb' => 'x' }, days_ago: 800)
          git('checkout', '-qb', 'side')
          commit('side change', { 'side.rb' => 'y' }, days_ago: 20)
          git('checkout', '-q', 'main')
          commit('unrelated', { 'other.rb' => 'y' }, days_ago: 10)
          git('merge', '--no-ff', '--no-commit', '-q', 'side')
          commit('merge with a new file', { 'fresh.rb' => body })

          expect(read('fresh.rb').fetch('fresh.rb')).to include(added: true, commit_count: 1)
        end

        it 'resolves two renames of one source on two branches by their own history' do
          commit('create', { 'source.rb' => body }, days_ago: 800)
          git('checkout', '-qb', 'side')
          rename('source.rb', 'side.rb', days_ago: 30)
          git('checkout', '-q', 'main')
          git('rm', '-q', 'source.rb')
          commit('delete', {}, days_ago: 60)
          commit('recreate', { 'source.rb' => "class Source\n  def fresh; end\nend\n" }, days_ago: 50)
          rename('source.rb', 'main.rb', days_ago: 20)
          _output, status = Open3.capture2e('git', '-C', root, 'merge', '--no-ff', 'side')
          expect(status.success?).to be(false)
          git('add', 'side.rb')
          git('commit', '-qm', 'keep both')

          facts = read('side.rb', 'main.rb')
          expect(facts.fetch('side.rb')).not_to have_key(:added)
          expect(facts.fetch('main.rb')).to include(added: true)
          expect(read('side.rb').fetch('side.rb')).to eq(facts.fetch('side.rb'))
        end
      end

      describe 'a history whose older commits are missing' do
        def build
          commit('create', { 'first.rb' => body }, days_ago: 800)
          rename('first.rb', 'second.rb', days_ago: 100)
          rename('second.rb', 'third.rb', days_ago: 3)
        end

        it 'reads the oldest commit of a shallow clone as creating its files' do
          build
          shallow = Dir.mktmpdir('woods_git_shallow')
          git('clone', '-q', '--depth', '2', "file://#{root}", shallow)

          facts = described_class.new(root: shallow, logger: logger)
                                 .read(['third.rb'], recent_after: Time.now - (90 * 86_400))
          expect(facts.fetch('third.rb')).to include(added: true, commit_count: 1)
        ensure
          FileUtils.rm_rf(shallow) if shallow
        end

        it 'reads a commit grafted to have no parent as creating its files' do
          build
          git('replace', '--graft', git('rev-parse', 'HEAD~1'))

          expect(read('third.rb').fetch('third.rb')).to include(added: true, commit_count: 1)
        end
      end
    end
  end

  it 'counts deletion and recreation at the same exact name' do
    commit('original', { 'sample.rb' => 'old' })
    git('rm', '-q', 'sample.rb')
    git('commit', '-qm', 'delete')
    commit('recreated', { 'sample.rb' => 'new' })

    expect(read('sample.rb').fetch('sample.rb')[:commits].map { |entry| entry[:message] })
      .to contain_exactly('original', 'delete', 'recreated')
  end

  it 'uses committer instants for the recent window despite author dates and timezone offsets' do
    cutoff = Time.now - (90 * 86_400)
    [cutoff - 3600, cutoff + 3600].each_with_index do |instant, index|
      File.write(File.join(root, 'sample.rb'), index.to_s)
      git('add', 'sample.rb')
      committer = instant.getlocal(index.zero? ? '+14:00' : '-12:00').iso8601
      git('commit', '-qm', "change #{index}", env: {
            'GIT_COMMITTER_DATE' => committer,
            'GIT_AUTHOR_DATE' => (Time.now - (index.zero? ? 0 : 200 * 86_400)).iso8601
          })
    end

    data = reader.read(['sample.rb'], recent_after: cutoff).fetch('sample.rb')
    expect(data).to include(commit_count: 2, recent_count: 1)
    expect(Time.iso8601(data[:last_modified])).to be_within(1).of(cutoff + 3600)
  end

  it 'maps repository paths into a nested Rails root without including siblings' do
    commit('root', { 'apps/nested/sample.rb' => 'yes', 'sample.rb' => 'no' })
    commit('sibling-only change', { 'sample.rb' => 'changed sibling' })
    git('config', 'diff.relative', 'true')
    nested = described_class.new(root: File.join(root, 'apps/nested'), logger: logger)
    result = nested.read(['sample.rb'], recent_after: Time.now - 86_400)
    expect(result.fetch('sample.rb')[:commit_count]).to eq(1)
  end

  it 'keeps total and recent counts while retaining only five commit records' do
    commit('too old', { 'sample.rb' => 'old' }, days_ago: 400)
    commit('within year', { 'sample.rb' => 'year' }, days_ago: 100)
    8.times { |i| commit("recent #{i}", { 'sample.rb' => i.to_s }, author: "Author #{i % 2}") }

    data = read('sample.rb').fetch('sample.rb')
    expect(data).to include(commit_count: 9, recent_count: 8)
    expect(data[:contributors]).to eq('Author' => 1, 'Author 0' => 4, 'Author 1' => 4)
    expect(data[:commits].size).to eq(5)
    expect(data[:commits].map { |c| c[:message] }).not_to include('too old')
  end

  [false, true].each do |partial|
    it "discards #{partial ? 'partial output' : 'unsupported-option output'} on a failed command and warns once" do
      commit('root', { 'sample.rb' => 'a' })
      allow(Open3).to receive(:capture3).and_return(["\n", '', double(success?: true)])
      stream = if partial
                 "\0#{'a' * 40}\0#{'b' * 40}\0Author\0#{Time.now.iso8601}\0subject\0\0" \
                   "\n:100644 100644 a b M\0sample.rb\0"
               else
                 ''
               end
      stdout = StringIO.new(stream)
      wait = double('Wait', value: double('Status', success?: false, exitstatus: 129))
      allow(Open3).to receive(:popen3).and_yield(StringIO.new, stdout, StringIO.new('unsupported option'), wait)
      expect(logger).to receive(:warn).once.with(/Git 2.31 or newer/)

      expect(read('sample.rb')).to be_nil
    end
  end

  it 'rejects an incomplete successful stream instead of publishing partial history' do
    commit('root', { 'sample.rb' => 'a' })
    allow(Open3).to receive(:capture3).and_return(["\n", '', double(success?: true)])
    wait = double('Wait', value: double('Status', success?: true, exitstatus: 0))
    allow(Open3).to receive(:popen3).and_yield(StringIO.new, StringIO.new("\0#{'a' * 40}\0Author"), StringIO.new, wait)
    expect(logger).to receive(:warn).once

    expect(read('sample.rb')).to be_nil
  end
end
