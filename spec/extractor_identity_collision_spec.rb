# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

RSpec.describe Woods::Extractor, 'identity collisions' do
  include_context 'isolated Woods runtime'

  let(:root) { Dir.mktmpdir('woods-identities') }
  let(:extractor) { described_class.new(output_dir: File.join(root, 'index')) }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(root), logger: double('Logger').as_null_object))
    extractor.instance_variable_set(:@eager_load_complete, true)
  end

  after { FileUtils.rm_rf(root) }

  def unit(path, type = :poro)
    Woods::ExtractedUnit.new(type: type, identifier: 'SharedIdentity', file_path: path)
  end

  def source(name)
    path = File.join(root, 'app/models', name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '# source')
    path
  end

  def register(*units)
    key = described_class::TYPE_TO_EXTRACTOR_KEY.fetch(units.first.type)
    extractor.send(:register_and_write, key, units, Set.new)
  end

  it 'rejects a new source claiming a retained typed identity before registration' do
    first = source('first.rb')
    second = source('second.rb')
    extractor.dependency_graph.register(unit(first))
    expect { register(unit(second)) }.to raise_error(Woods::ExtractionError, /same-type identifier collision/)
    expect(extractor.dependency_graph.node('SharedIdentity', type: :poro)[:file_path]).to eq(first)
  end

  it 'rejects two fresh claims even after the first source disappears' do
    first = source('first.rb')
    register(unit(first))
    File.unlink(first)
    expect { register(unit(source('second.rb'))) }.to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'checks a whole batch before writing any of its conflicting units' do
    expect(extractor).not_to receive(:write_unit_file)
    expect { register(unit(source('first.rb')), unit(source('second.rb'))) }
      .to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'accepts repeated same-file results and relative versus absolute paths' do
    path = source('first.rb')
    relative = path.delete_prefix("#{root}/")
    expect(register(unit(path), unit(relative))).to eq(Set['SharedIdentity'])
    expect { register(unit(path)) }.not_to raise_error
  end

  it 'keeps different unit types independent' do
    register(unit(source('first.rb')))
    expect { register(unit(source('second.rb'), :service)) }.not_to raise_error
    expect(extractor.dependency_graph.node_types('SharedIdentity')).to contain_exactly(:poro, :service)
  end

  it 'accepts a retained source move after its old regular file is removed' do
    first = source('first.rb')
    extractor.dependency_graph.register(unit(first))
    File.unlink(first)
    second = source('second.rb')
    expect { register(unit(second)) }.not_to raise_error
    expect(extractor.dependency_graph.node('SharedIdentity', type: :poro)[:file_path]).to eq(second)
  end

  it 'does not mistake a dangling symlink for a removed source' do
    first = source('first.rb')
    extractor.dependency_graph.register(unit(first))
    File.unlink(first)
    File.symlink(File.join(root, 'missing'), first)
    expect { register(unit(source('second.rb'))) }.to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'rejects fileless versus file-owned claims' do
    extractor.dependency_graph.register(unit(nil))
    expect { register(unit(source('second.rb'))) }.to raise_error(Woods::ExtractionError, /collision/)
  end

  describe 'moves out of surviving source files' do
    let(:old_path) { source('old.rb') }
    let(:new_path) { source('new.rb') }

    def reconcile_file_candidates(candidates, order)
      rule = Woods::PathDispatcher::Rule.new(extractor_key: :services, method_name: :extract_service_file)
      dispatcher = double('Dispatcher', file_rules_for: [rule])
      allow(Woods::PathDispatcher).to receive(:new).and_return(dispatcher)
      allow(extractor).to receive(:extract_with_rule) { |_rule, path| candidates.fetch(path) }
      extractor.send(:reconcile_changed_paths, Woods::ChangeSet.new(paths: order, root: root), Set.new)
    end

    [false, true].each do |new_first|
      it "moves a file-derived identity only after collecting both paths, new first=#{new_first}" do
        extractor.dependency_graph.register(unit(old_path, :service))
        order = new_first ? [new_path, old_path] : [old_path, new_path]

        reconcile_file_candidates({ old_path => [], new_path => [unit(new_path, :service)] }, order)

        expect(extractor.dependency_graph.node('SharedIdentity', type: :service)[:file_path]).to eq(new_path)
        expect(extractor.dependency_graph.units_for_path(old_path)).to be_empty
        expect(File).to exist(old_path)
      end

      it "rejects simultaneous owners before any write or prune, new first=#{new_first}" do
        extractor.dependency_graph.register(unit(old_path, :service))
        candidates = { old_path => [unit(old_path, :service)], new_path => [unit(new_path, :service)] }
        order = new_first ? [new_path, old_path] : [old_path, new_path]
        expect(extractor).not_to receive(:write_unit_file)
        expect(extractor).not_to receive(:remove_unit)

        expect { reconcile_file_candidates(candidates, order) }.to raise_error(Woods::IdentityCollisionError)
        expect(extractor.dependency_graph.node('SharedIdentity', type: :service)[:file_path]).to eq(old_path)
      end
    end

    it 'does not treat failed prior-path discovery as proof that its identity moved' do
      extractor.dependency_graph.register(unit(old_path, :service))
      expect(extractor).not_to receive(:write_unit_file)
      expect do
        reconcile_file_candidates({ old_path => nil, new_path => [unit(new_path, :service)] }, [old_path, new_path])
      end.to raise_error(Woods::IdentityCollisionError)
    end

    it 'does not release identities when a configured per-file method is unavailable' do
      extractor.dependency_graph.register(unit(old_path, :service))
      extractor.instance_variable_set(:@incremental_extractors, { services: Object.new })
      rule = Woods::PathDispatcher::Rule.new(extractor_key: :services, method_name: :extract_service_file)
      allow(Woods::PathDispatcher).to receive(:new).and_return(double('Dispatcher', file_rules_for: [rule]))

      extractor.send(:reconcile_changed_paths, Woods::ChangeSet.new(paths: [old_path], root: root), Set.new)

      expect(extractor.dependency_graph.node('SharedIdentity', type: :service)[:file_path]).to eq(old_path)
    end

    it 'does not release file-derived owners during an incomplete eager load' do
      extractor.dependency_graph.register(unit(old_path, :service))
      extractor.instance_variable_set(:@eager_load_complete, false)
      expect do
        reconcile_file_candidates({ old_path => [], new_path => [unit(new_path, :service)] }, [old_path, new_path])
      end.to raise_error(Woods::IdentityCollisionError)
    end

    def install_runtime_owner
      stub_const('SharedIdentity', Class.new)
      Object.send(:remove_const, :SharedIdentity)
      File.write(new_path, 'class SharedIdentity; end')
      load new_path
      consumer = double('ModelExtractor', discoverable_classes: [SharedIdentity])
      extractor.instance_variable_set(:@incremental_extractors, { models: consumer })
      extractor.dependency_graph.register(unit(old_path, :model))
      consumer
    end

    it 'accepts the unique canonical owner from complete runtime discovery' do
      install_runtime_owner
      expect { register(unit(new_path, :model)) }.not_to raise_error
      expect(extractor.dependency_graph.node('SharedIdentity', type: :model)[:file_path]).to eq(new_path)
      expect(File).to exist(old_path)
    end

    it 'refuses runtime moves after incomplete eager loading' do
      install_runtime_owner
      extractor.instance_variable_set(:@eager_load_complete, false)
      expect { register(unit(new_path, :model)) }.to raise_error(Woods::IdentityCollisionError)
    end

    it 'refuses a producer path that disagrees with the canonical runtime owner' do
      install_runtime_owner
      expect { register(unit(source('third.rb'), :model)) }.to raise_error(Woods::IdentityCollisionError)
    end

    it 'refuses ambiguity in the completed runtime inventory' do
      consumer = install_runtime_owner
      other = double('Other class', name: 'SharedIdentity')
      allow(consumer).to receive(:discoverable_classes).and_return([SharedIdentity, other])
      expect { register(unit(new_path, :model)) }.to raise_error(Woods::IdentityCollisionError)
    end

    it 'does not trust a runtime inventory whose discovery handled an error' do
      consumer = install_runtime_owner
      allow(consumer).to receive(:discoverable_classes) do
        Woods::SourceInputs::ConsumerErrors.record(consumer)
        [SharedIdentity]
      end
      expect { register(unit(new_path, :model)) }.to raise_error(Woods::IdentityCollisionError)
    end
  end

  it 'propagates a wholesale collision before the first mutation' do
    consumer = double('PoroExtractor', extract_all: [unit(source('first.rb')), unit(source('second.rb'))])
    extractor.instance_variable_set(:@incremental_extractors, { poros: consumer })
    expect { extractor.send(:replace_type_wholesale, :poros, Set.new) }
      .to raise_error(Woods::ExtractionError, /collision/)
    expect(extractor.dependency_graph.node('SharedIdentity')).to be_nil
  end

  it 'allows authoritative wholesale replacement to relocate a framework source' do
    old = source('old.rb')
    replacement = source('new.rb')
    extractor.dependency_graph.register(unit(old, :rails_source))
    consumer = double('FrameworkExtractor', extract_all: [unit(replacement, :rails_source)])
    extractor.instance_variable_set(:@incremental_extractors, { rails_source: consumer })
    expect { extractor.send(:replace_type_wholesale, :rails_source, Set.new) }.not_to raise_error
    expect(extractor.dependency_graph.node('SharedIdentity', type: :rails_source)[:file_path]).to eq(replacement)
  end

  it 'does not grant replacement authority to incomplete runtime discovery' do
    old = source('old.rb')
    extractor.dependency_graph.register(unit(old, :controller))
    consumer = double('ControllerExtractor', extract_all: [unit(source('new.rb'), :controller)])
    extractor.instance_variable_set(:@incremental_extractors, { controllers: consumer })
    extractor.instance_variable_set(:@eager_load_complete, false)
    expect { extractor.send(:replace_type_wholesale, :controllers, Set.new) }
      .to raise_error(Woods::ExtractionError, /collision/)
    expect(extractor.dependency_graph.node('SharedIdentity', type: :controller)[:file_path]).to eq(old)
  end

  it 'refuses cross-source identities that share one extractor payload path' do
    a = unit(source('first.rb'), :graphql_type)
    b = unit(source('second.rb'), :graphql_query)
    expect { extractor.send(:deduplicate_type_units, :graphql, [a, b]) }
      .to raise_error(Woods::ExtractionError, /collision/)
  end

  it 'does not transfer a GraphQL identity to a conflicting source while changing its kind' do
    prior = unit(source('first.rb'), :graphql_type)
    fresh = unit(source('second.rb'), :graphql_query)
    extractor.dependency_graph.register(prior)
    klass = double('GraphQL class', name: prior.identifier)
    consumer = double('GraphQLExtractor', runtime_discovery_complete?: true,
                                          runtime_unit_type: :graphql_query, extract_from_runtime_type: fresh)

    expect do
      extractor.send(:reconcile_graphql_classification, consumer, [klass], Set.new, Set.new)
    end.to raise_error(Woods::ExtractionError, /collision/)
    expect(extractor.dependency_graph.node_types(prior.identifier)).to eq([:graphql_type])
  end

  %i[changed_file refresh].each do |operation|
    it "refuses #{operation} GraphQL role changes after incomplete eager loading without replacing old payloads" do
      stub_const('GraphQL::Schema', Class.new { def self.descendants = [] })
      stub_const('GraphQL::Schema::Object', Class.new)
      stub_const('SharedIdentity', Class.new(GraphQL::Schema::Object))
      path = File.join(root, 'app/graphql/shared_identity.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, 'class SharedIdentity < GraphQL::Schema::Object; end')
      register(unit(path, :graphql_query))
      filename = extractor.send(:collision_safe_filename, 'SharedIdentity')
      payload = extractor.send(:payload_dir).join('graphql', filename)
      previous = File.binread(payload)
      File.write(path, "#{File.read(path)}\n# changed source\n")
      extractor.instance_variable_set(:@eager_load_complete, false)
      consumer = Woods::Extractors::GraphQLExtractor.new
      extractor.instance_variable_set(:@incremental_extractors, { graphql: consumer })
      expect(consumer.runtime_discovery_complete?).to be(true)

      expect do
        if operation == :changed_file
          changes = Woods::ChangeSet.new(paths: [path], root: root)
          extractor.send(:reconcile_changed_paths, changes, Set.new)
        else
          extractor.send(:replace_type_wholesale, :graphql, Set.new)
        end
        extractor.send(:raise_on_handled_extraction_failure!)
      end.to raise_error(Woods::ExtractionError, /[Gg]raphql|GraphQL/)
      expect(extractor.dependency_graph.node_types('SharedIdentity')).to eq([:graphql_query])
      expect(File.binread(payload)).to eq(previous)
    end
  end

  it 'does not authorize conflicting fresh GraphQL owners across kinds during wholesale replacement' do
    register(unit(source('first.rb'), :graphql_type))
    fresh = unit(source('second.rb'), :graphql_query)

    expect do
      extractor.send(:with_replacement_ownership, :graphql) { register(fresh) }
    end.to raise_error(Woods::ExtractionError, /collision/)
    expect(extractor.dependency_graph.node_types('SharedIdentity')).to eq([:graphql_type])
  end
end
