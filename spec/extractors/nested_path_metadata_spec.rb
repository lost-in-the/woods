# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

RSpec.describe 'App-owned nested extractor paths' do
  include_context 'extractor setup'

  def write_source(root, relative, source)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def in_each_root
    %w[first_checkout another_checkout].map do |name|
      root = File.join(tmp_dir, name)
      FileUtils.mkdir_p(root)
      allow(Rails).to receive(:root).and_return(Pathname.new(root))
      yield root
    end
  end

  def serialized_unit(unit)
    # Apply the writer's existing top-level normalization, never scrub nested
    # metadata or source. Only the legitimate extraction timestamp is omitted.
    writer = Woods::Extractor.new(output_dir: Rails.root.join('index'))
    writer.instance_variable_set(:@results, units: [unit])
    writer.send(:normalize_file_paths)
    JSON.parse(JSON.generate(unit.to_h)).except('extracted_at')
  end

  %i[active_support wisper].each do |pattern|
    it "keeps #{pattern} event metadata, annotations and source hashes equal across checkouts" do
      publisher = if pattern == :active_support
                    'ActiveSupport::Notifications.instrument("order.created")'
                  else
                    'include Wisper::Publisher; broadcast(:order_created)'
                  end
      subscriber = if pattern == :active_support
                     'ActiveSupport::Notifications.subscribe("order.created") {}'
                   else
                     'Wisper.subscribe(listener); publisher.on(:order_created) {}'
                   end
      records = in_each_root do |root|
        write_source(root, 'app/services/a_order.rb', "#{publisher}\n#{publisher}\nOrderService.call\n")
        write_source(root, 'app/services/z_order.rb', publisher)
        write_source(root, 'app/listeners/order_listener.rb', "#{subscriber}\nShippingJob.perform_later\n")
        unit = Woods::Extractors::EventExtractor.new.extract_all.fetch(0)

        expect(unit.file_path).to eq(File.join(root, 'app/services/a_order.rb'))
        expect(unit.metadata).to include(
          publishers: %w[app/services/a_order.rb app/services/z_order.rb],
          subscribers: ['app/listeners/order_listener.rb'], publisher_count: 2, subscriber_count: 1
        )
        expect(unit.source_code).to include('# Publishers: app/services/a_order.rb, app/services/z_order.rb',
                                            '# Subscribers: app/listeners/order_listener.rb')
        expect(unit.dependencies.map { |dependency| dependency[:target] }).to include('OrderService', 'ShippingJob')
        serialized_unit(unit)
      end

      expect(records.last).to eq(records.first)
      expect(records.first.fetch('source_hash')).to match(/\A[0-9a-f]{64}\z/)
      expect(JSON.generate(records)).not_to include(tmp_dir)
    end
  end

  ['.html.erb', '.html.haml', '.html.slim', '/portable_metadata_component.html.erb'].each do |suffix|
    it "keeps ViewComponent metadata and source hashes equal across checkouts for #{suffix}" do
      stub_const('ViewComponent::Base', Class.new)
      source = <<~RUBY
        class PortableMetadataComponent < ViewComponent::Base
          def initialize(title:)
            @title = title
          end

          def call
            @title
          end
        end
      RUBY
      template = "app/components/portable_metadata_component#{suffix}"
      records = in_each_root do |root|
        stub_const('PortableMetadataComponent', Class.new(ViewComponent::Base))
        path = write_source(root, 'app/components/portable_metadata_component.rb', source)
        write_source(root, template, '<h1><%= @title %></h1>')
        load path
        unit = Woods::Extractors::ViewComponentExtractor.new.extract_component(PortableMetadataComponent)

        expect(unit.file_path).to eq(path)
        expect(unit.source_code).to eq(source)
        expect(unit.metadata.fetch(:sidecar_template)).to eq(template)
        serialized_unit(unit)
      end

      expect(records.last).to eq(records.first)
      expect(records.first.fetch('source_hash')).to eq(Digest::SHA256.hexdigest(source))
      expect(JSON.generate(records)).not_to include(tmp_dir)
    end
  end

  it 'keeps explicitly scanned external event paths absolute, including a sibling with the same root prefix' do
    app = File.join(tmp_dir, 'app')
    FileUtils.mkdir_p(app)
    allow(Rails).to receive(:root).and_return(Pathname.new(app))
    path = write_source("#{app}-external", 'events.rb', <<~RUBY)
      ActiveSupport::Notifications.instrument('external.event')
      ActiveSupport::Notifications.subscribe('external.event') {}
      ExternalService.call
    RUBY
    extractor = Woods::Extractors::EventExtractor.new
    events = {}
    extractor.scan_file(path, events)
    unit = extractor.send(:build_unit, 'external.event', events.fetch('external.event'))

    expect(events.fetch('external.event')).to include(publishers: [path], subscribers: [path])
    expect(unit.metadata).to include(publishers: [path], subscribers: [path])
    expect(unit.source_code).to include("# Publishers: #{path}", "# Subscribers: #{path}")
    expect(unit.dependencies.map { |dependency| dependency[:target] }).to include('ExternalService')
    expect(serialized_unit(unit).fetch('file_path')).to eq(path)
  end

  it 'preserves an external component source path without inventing a sidecar' do
    stub_const('ViewComponent::Base', Class.new)
    stub_const('PortableMetadataComponent', Class.new(ViewComponent::Base))
    app = File.join(tmp_dir, 'app')
    FileUtils.mkdir_p(app)
    allow(Rails).to receive(:root).and_return(Pathname.new(app))
    source = 'class PortableMetadataComponent < ViewComponent::Base; def call; "external"; end; end'
    path = write_source("#{app}-external", 'portable_metadata_component.rb', source)
    load path

    unit = Woods::Extractors::ViewComponentExtractor.new.extract_component(PortableMetadataComponent)

    expect(unit.source_code).to eq(source)
    expect(unit.metadata.fetch(:sidecar_template)).to be_nil
    expect(serialized_unit(unit).fetch('file_path')).to eq(path)
  end
end
