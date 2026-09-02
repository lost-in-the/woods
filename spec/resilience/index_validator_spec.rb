# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/resilience/index_validator'

RSpec.describe Woods::Resilience::IndexValidator do
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_json(relative_path, data)
    full_path = File.join(tmp_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, JSON.generate(data))
  end

  def write_unit_file(type_dir, filename, source_code: 'class Foo; end')
    data = {
      'identifier' => filename.sub('.json', ''),
      'type' => 'model',
      'source_code' => source_code,
      'source_hash' => Digest::SHA256.hexdigest(source_code)
    }
    write_json(File.join(type_dir, filename), data)
  end

  describe '#validate' do
    context 'with a valid index' do
      before do
        write_unit_file('models', 'User.json', source_code: 'class User; end')
        write_unit_file('models', 'Order.json', source_code: 'class Order; end')

        index = [
          { 'identifier' => 'User', 'file_path' => 'app/models/user.rb' },
          { 'identifier' => 'Order', 'file_path' => 'app/models/order.rb' }
        ]
        write_json('models/_index.json', index)
      end

      it 'returns a valid report' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be true
        expect(report.errors).to be_empty
        expect(report.warnings).to be_empty
      end
    end

    context 'with a manifest (B-128: the woods:validate checks)' do
      before do
        write_unit_file('models', 'User.json', source_code: 'class User; end')
        write_json('models/_index.json', [{ 'identifier' => 'User', 'file_path' => 'app/models/user.rb' }])
        write_json('manifest.json', { 'counts' => { 'models' => 2, 'controllers' => 1 } })
      end

      it 'warns when a manifest count disagrees with the files on disk' do
        report = described_class.new(index_dir: tmp_dir).validate
        expect(report.warnings).to include('models: expected 2, found 1')
      end

      it 'reports a type directory the manifest names but the disk lacks' do
        report = described_class.new(index_dir: tmp_dir).validate
        expect(report.errors).to include('Missing directory: controllers')
      end

      it 'reports a missing dependency graph' do
        report = described_class.new(index_dir: tmp_dir).validate
        expect(report.errors).to include('Missing dependency_graph.json')
      end

      it 'warns about unit file paths that resolve nowhere when given an app root' do
        write_json('models/User.json', { 'identifier' => 'User', 'source_code' => 'class User; end',
                                         'file_path' => 'app/models/user.rb' })
        report = described_class.new(index_dir: tmp_dir, app_root: tmp_dir).validate
        expect(report.warnings.grep(/models: 1 unit\(s\) whose file_path resolves nowhere/)).not_to be_empty
      end

      it 'separates gem-owned unit paths from app paths that resolve nowhere' do
        # An engine model's file lives in a gem, not the application tree, so it
        # is expected to be absent under the app root. Telling the operator to
        # re-run extraction is a no-op remedy for that case.
        write_json('models/User.json', { 'identifier' => 'User', 'source_code' => 'class User; end',
                                         'file_path' => 'app/models/user.rb' })
        write_json('models/Attachment.json',
                   { 'identifier' => 'Attachment', 'source_code' => 'class Attachment; end',
                     'file_path' => '/nonexistent/gems/storage-1.0/app/models/attachment.rb' })
        report = described_class.new(index_dir: tmp_dir, app_root: tmp_dir).validate

        outside = report.warnings.grep(/models: 1 unit\(s\) whose file_path lies outside the app root/)
        expect(outside).not_to be_empty
        expect(outside.first).to include('Attachment')
        expect(outside.first).not_to include('Re-run extraction')
        # User.json (relative path, missing) still gets the app-tree warning.
        expect(report.warnings.grep(/models: 1 unit\(s\) whose file_path resolves nowhere/)).not_to be_empty
      end

      it 'reports a unit file without source_code' do
        write_json('models/Order.json', { 'identifier' => 'Order' })
        report = described_class.new(index_dir: tmp_dir).validate
        expect(report.errors.grep(/Order\.json: missing source_code/)).not_to be_empty
      end
    end

    context 'with missing _index.json' do
      before do
        # Create a type directory with unit files but no _index.json
        write_unit_file('models', 'User.json')
      end

      it 'reports an error for the missing index' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be false
        expect(report.errors).to include(a_string_matching(/_index\.json/))
      end
    end

    context 'with a flows/ artifact directory (G-2)' do
      # flows/ holds flow_index.json plus per-flow documents — no
      # _index.json, no units. It used to be swept into the unit-type
      # structural pass, so every index published with flow precomputation
      # on failed validation with "Missing _index.json in flows/".
      before do
        write_json('flows/flow_index.json',
                   { 'PostsController#create' => 'flows/PostsController_create.json' })
        write_json('flows/PostsController_create.json',
                   { 'entry_point' => 'PostsController#create', 'steps' => [] })
      end

      it 'validates clean — flows/ is not a unit-type directory' do
        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).not_to include(a_string_matching(/flows/))
        expect(report.valid?).to be true
      end

      it 'reports a flow document the index references but the disk lacks' do
        File.delete(File.join(tmp_dir, 'flows', 'PostsController_create.json'))

        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).to include(a_string_matching(/missing document.*PostsController_create\.json/))
      end

      it 'reports a malformed flow document' do
        FileUtils.mkdir_p(File.join(tmp_dir, 'flows'))
        File.write(File.join(tmp_dir, 'flows', 'PostsController_create.json'), '{ not json')

        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).to include(a_string_matching(/PostsController_create\.json: invalid JSON/))
      end

      it 'reports a malformed flow index itself' do
        File.write(File.join(tmp_dir, 'flows', 'flow_index.json'), '{ not json')

        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).to include(a_string_matching(/flow_index\.json: invalid JSON/))
      end

      it 'reports a populated flow family whose flow_index.json is missing' do
        File.delete(File.join(tmp_dir, 'flows', 'flow_index.json'))
        File.write(File.join(tmp_dir, 'flows', 'Orphaned.json'), '{ ok }')

        report = described_class.new(index_dir: tmp_dir).validate

        # A populated family with no index is corruption, not an absence:
        # the index is what defines which documents are live.
        expect(report.errors).to include(a_string_matching(/populated.*flow_index\.json is missing/))
      end

      it 'leaves a genuinely empty flows/ directory alone' do
        File.delete(File.join(tmp_dir, 'flows', 'flow_index.json'))
        File.delete(File.join(tmp_dir, 'flows', 'PostsController_create.json'))

        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).to be_empty
      end
    end

    context 'with flows/ beside a manifest-counted type directory' do
      # The manifest-driven path must leave flows/ to the flow validator,
      # not pick it up as a counted type directory.
      before do
        write_unit_file('models', 'User.json', source_code: 'class User; end')
        write_json('models/_index.json', [{ 'identifier' => 'User', 'file_path' => 'app/models/user.rb' }])
        write_json('manifest.json', { 'counts' => { 'models' => 1 } })
        write_json('dependency_graph.json', { 'nodes' => {} })
        write_json('flows/flow_index.json', { 'PostsController#show' => 'flows/PostsController_show.json' })
        write_json('flows/PostsController_show.json', { 'entry_point' => 'PostsController#show', 'steps' => [] })
      end

      it 'validates clean' do
        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).to be_empty
      end
    end

    context 'when the type-directory allowlist cannot be derived' do
      # The allowlist comes from the shared extraction contract. A
      # derivation failure used to degrade to a silently empty allowlist,
      # which disabled every structural type-directory check instead of
      # saying so.
      before do
        write_unit_file('models', 'User.json')
        allow(described_class).to receive(:unit_type_directories)
          .and_raise(LoadError, 'cannot load the extraction contract')
      end

      it 'reports the derivation failure instead of silently disabling checks' do
        report = described_class.new(index_dir: tmp_dir).validate

        expect(report.errors).to include(a_string_matching(/unit-type directory allowlist/))
        expect(report.valid?).to be false
      end
    end

    context 'with missing referenced files' do
      before do
        write_unit_file('models', 'User.json')

        index = [
          { 'identifier' => 'User', 'file_path' => 'app/models/user.rb' },
          { 'identifier' => 'Order', 'file_path' => 'app/models/order.rb' }
        ]
        write_json('models/_index.json', index)
      end

      it 'reports an error for the missing unit file' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be false
        expect(report.errors).to include(a_string_matching(/Order/))
      end
    end

    context 'with a content_hash mismatch' do
      before do
        data = {
          'identifier' => 'User',
          'type' => 'model',
          'source_code' => 'class User; end',
          'source_hash' => 'deadbeef_wrong_hash'
        }
        write_json('models/User.json', data)

        index = [{ 'identifier' => 'User', 'file_path' => 'app/models/user.rb' }]
        write_json('models/_index.json', index)
      end

      it 'reports an error for the hash mismatch' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be false
        expect(report.errors).to include(a_string_matching(/hash.*mismatch.*User/i))
      end
    end

    context 'with stale files not in the index' do
      before do
        write_unit_file('models', 'User.json')
        write_unit_file('models', 'Stale.json')

        index = [{ 'identifier' => 'User', 'file_path' => 'app/models/user.rb' }]
        write_json('models/_index.json', index)
      end

      it 'reports a warning for stale files' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.warnings).to include(a_string_matching(/Stale/))
      end

      it 'is still valid (warnings do not invalidate)' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be true
      end
    end

    context 'with an empty index directory' do
      it 'returns a valid report with no issues' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be true
        expect(report.errors).to be_empty
        expect(report.warnings).to be_empty
      end
    end

    context 'with a non-existent directory' do
      it 'reports an error' do
        validator = described_class.new(index_dir: File.join(tmp_dir, 'nonexistent'))
        report = validator.validate

        expect(report.valid?).to be false
        expect(report.errors).to include(a_string_matching(/does not exist/))
      end
    end

    context 'when the published payload directory is missing on disk' do
      # `Generation#payload_dir` resolves to whatever directory is currently
      # on disk at the time it's asked, so a directory that vanishes between
      # that check and the `Dir.children` call below (e.g. a concurrent
      # promote/prune) is a real, if narrow, race — reproduced here by
      # stubbing `Dir.children` directly rather than trying to win the race.
      it 'reports an error instead of raising Errno::ENOENT' do
        validator = described_class.new(index_dir: tmp_dir)

        # Raise only on the single Dir.children(payload) call #validate makes
        # (payload resolves to tmp_dir here, with no generation.json
        # published) — not on any Dir.children call FileUtils.rm_rf makes
        # during the `after` cleanup for this same directory.
        raised = false
        allow(Dir).to receive(:children).and_wrap_original do |original, *args|
          if !raised && args.first == tmp_dir
            raised = true
            raise Errno::ENOENT
          else
            original.call(*args)
          end
        end

        report = nil
        expect { report = validator.validate }.not_to raise_error
        expect(report.valid?).to be false
        expect(report.errors).to include(a_string_matching(/Payload directory does not exist/))
      end
    end

    context 'with multibyte content under a non-UTF-8 default external encoding' do
      # AtomicFile.write is binmode, so bytes land verbatim regardless of the
      # process's default external encoding — but a bare File.read tags what
      # comes back with that encoding, and a container with no locale set
      # (LANG=C, US-ASCII) raised Encoding::InvalidByteSequenceError on the
      # first JSON.parse of any artifact containing e.g. an em dash.
      around do |example|
        original = Encoding.default_external
        Encoding.default_external = Encoding::US_ASCII
        example.run
      ensure
        Encoding.default_external = original
      end

      before do
        source_code = 'class Foo; end # em dash —'
        data = {
          'identifier' => 'Foo',
          'type' => 'model',
          'source_code' => source_code,
          'source_hash' => Digest::SHA256.hexdigest(source_code)
        }
        # binwrite, not the write_json helper: writing a UTF-8 string through
        # a text-mode File.write under a US-ASCII default external encoding
        # would raise on the write side, before the read path under test
        # ever runs.
        FileUtils.mkdir_p(File.join(tmp_dir, 'models'))
        File.binwrite(File.join(tmp_dir, 'models', 'Foo.json'), JSON.generate(data))
        index = [{ 'identifier' => 'Foo', 'file_path' => 'app/models/foo.rb' }]
        File.binwrite(File.join(tmp_dir, 'models', '_index.json'), JSON.generate(index))
      end

      it 'validates the multibyte artifact without raising Encoding::InvalidByteSequenceError' do
        validator = described_class.new(index_dir: tmp_dir)

        report = nil
        expect { report = validator.validate }.not_to raise_error
        expect(report.valid?).to be true
        expect(report.errors).to be_empty
      end
    end
  end

  describe '#safe_filename (alignment with Extractor)' do
    let(:validator) { described_class.new(index_dir: tmp_dir) }

    it 'converts :: to __ for namespaced identifiers' do
      # This mirrors Extractor#safe_filename exactly
      expect(validator.send(:safe_filename, 'Admin::UsersController')).to eq('Admin__UsersController.json')
    end

    it 'replaces special characters with underscores' do
      expect(validator.send(:safe_filename, 'My::Widget/thing')).to eq('My__Widget_thing.json')
    end

    it 'leaves alphanumeric, underscores, and hyphens intact' do
      expect(validator.send(:safe_filename, 'FooBar_Baz-123')).to eq('FooBar_Baz-123.json')
    end

    it 'appends .json extension' do
      expect(validator.send(:safe_filename, 'User')).to eq('User.json')
    end

    context 'with a namespaced unit file on disk' do
      before do
        # Write a unit file using Extractor-style naming
        write_unit_file('models', 'Admin__UsersController.json', source_code: 'class Admin::UsersController; end')
        index = [{ 'identifier' => 'Admin::UsersController',
                   'file_path' => 'app/controllers/admin/users_controller.rb' }]
        write_json('models/_index.json', index)
      end

      it 'finds the file via safe_filename when exact match does not exist' do
        validator = described_class.new(index_dir: tmp_dir)
        report = validator.validate

        expect(report.valid?).to be true
        expect(report.errors).to be_empty
      end
    end
  end

  describe 'ValidationReport' do
    it 'is a Struct with valid?, warnings, and errors' do
      report = Woods::Resilience::IndexValidator::ValidationReport.new(
        valid?: true,
        warnings: ['some warning'],
        errors: []
      )

      expect(report.valid?).to be true
      expect(report.warnings).to eq(['some warning'])
      expect(report.errors).to eq([])
    end
  end
end
