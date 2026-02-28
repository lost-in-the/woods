# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extracted_unit'
require 'codebase_index/extractors/action_cable_extractor'

RSpec.describe CodebaseIndex::Extractors::ActionCableExtractor do
  subject(:extractor) { described_class.new }

  before do
    stub_const('CodebaseIndex::ModelNameCache',
               double('ModelNameCache', model_names_regex: /\b(?:User|Post|Room)\b/))
    stub_rails_root('/rails')
  end

  describe '#extract_all' do
    context 'when ActionCable::Channel::Base is not defined' do
      before do
        hide_const('ActionCable::Channel::Base') if defined?(ActionCable::Channel::Base)
        hide_const('ActionCable') if defined?(ActionCable)
      end

      it 'returns an empty array' do
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when ActionCable is defined but no channel subclasses exist' do
      before do
        stub_action_cable_base
        allow(channel_base_class).to receive(:descendants).and_return([])
      end

      it 'returns an empty array' do
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'with a single channel' do
      let(:channel_source) do
        <<~RUBY
          class ChatChannel < ApplicationCable::Channel
            def subscribed
              stream_from "chat_room_\#{params[:room_id]}"
            end

            def unsubscribed
              # cleanup
            end

            def speak(data)
              Message.create!(content: data['message'])
            end

            def typing(data)
              ActionCable.server.broadcast("chat_room_\#{params[:room_id]}", typing: data['user'])
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'ChatChannel',
          source: channel_source,
          public_methods: %i[subscribed unsubscribed speak typing],
          source_location: '/rails/app/channels/chat_channel.rb'
        )
        stub_const('ApplicationCable::Channel', Class.new)
        allow(base).to receive(:descendants).and_return([@channel, ApplicationCable::Channel])
      end

      it 'returns one unit (filters out ApplicationCable::Channel)' do
        units = extractor.extract_all
        expect(units.size).to eq(1)
      end

      it 'sets type to :action_cable_channel' do
        units = extractor.extract_all
        expect(units.first.type).to eq(:action_cable_channel)
      end

      it 'uses channel class name as identifier' do
        units = extractor.extract_all
        expect(units.first.identifier).to eq('ChatChannel')
      end

      it 'sets namespace to nil for top-level channel' do
        units = extractor.extract_all
        expect(units.first.namespace).to be_nil
      end

      it 'sets file_path from source_location' do
        units = extractor.extract_all
        expect(units.first.file_path).to eq('/rails/app/channels/chat_channel.rb')
      end

      it 'sets source_code' do
        units = extractor.extract_all
        expect(units.first.source_code).to eq(channel_source)
      end
    end

    context 'stream name detection' do
      let(:channel_source) do
        <<~RUBY
          class NotificationsChannel < ApplicationCable::Channel
            def subscribed
              stream_from "notifications_\#{current_user.id}"
              stream_for current_user
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'NotificationsChannel',
          source: channel_source,
          public_methods: %i[subscribed],
          source_location: '/rails/app/channels/notifications_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'detects stream_from names' do
        units = extractor.extract_all
        expect(units.first.metadata[:stream_names]).to include("notifications_\#{current_user.id}")
      end

      it 'detects stream_for models' do
        units = extractor.extract_all
        expect(units.first.metadata[:stream_names]).to include('stream_for:current_user')
      end
    end

    context 'action detection' do
      let(:channel_source) do
        <<~RUBY
          class GameChannel < ApplicationCable::Channel
            def subscribed
              stream_from "game"
            end

            def move(data)
            end

            def resign
            end

            private

            def find_game
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'GameChannel',
          source: channel_source,
          public_methods: %i[subscribed move resign],
          source_location: '/rails/app/channels/game_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'includes public methods minus subscribed/unsubscribed as actions' do
        units = extractor.extract_all
        expect(units.first.metadata[:actions]).to contain_exactly('move', 'resign')
      end
    end

    context 'has_subscribed and has_unsubscribed booleans' do
      let(:subscribed_source) do
        <<~RUBY
          class PresenceChannel < ApplicationCable::Channel
            def subscribed
              stream_from "presence"
            end
          end
        RUBY
      end

      let(:both_source) do
        <<~RUBY
          class FullChannel < ApplicationCable::Channel
            def subscribed
              stream_from "full"
            end

            def unsubscribed
              # cleanup
            end
          end
        RUBY
      end

      let(:empty_source) do
        <<~RUBY
          class EmptyChannel < ApplicationCable::Channel
          end
        RUBY
      end

      it 'detects has_subscribed when subscribed is defined' do
        base = stub_action_cable_base
        channel = build_mock_channel(
          'PresenceChannel',
          source: subscribed_source,
          public_methods: %i[subscribed],
          source_location: '/rails/app/channels/presence_channel.rb'
        )
        stub_application_cable_channel(base, [channel])

        units = extractor.extract_all
        expect(units.first.metadata[:has_subscribed]).to be true
      end

      it 'detects has_unsubscribed when unsubscribed is defined' do
        base = stub_action_cable_base
        channel = build_mock_channel(
          'FullChannel',
          source: both_source,
          public_methods: %i[subscribed unsubscribed],
          source_location: '/rails/app/channels/full_channel.rb'
        )
        stub_application_cable_channel(base, [channel])

        units = extractor.extract_all
        expect(units.first.metadata[:has_unsubscribed]).to be true
      end

      it 'sets has_subscribed to false when not defined' do
        base = stub_action_cable_base
        channel = build_mock_channel(
          'EmptyChannel',
          source: empty_source,
          public_methods: [],
          source_location: '/rails/app/channels/empty_channel.rb'
        )
        stub_application_cable_channel(base, [channel])

        units = extractor.extract_all
        expect(units.first.metadata[:has_subscribed]).to be false
      end
    end

    context 'broadcast detection' do
      let(:broadcast_source) do
        <<~RUBY
          class AlertChannel < ApplicationCable::Channel
            def subscribed
              stream_from "alerts"
            end

            def send_alert(data)
              ActionCable.server.broadcast("alerts", message: data['text'])
              AlertChannel.broadcast_to(current_user, urgent: true)
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'AlertChannel',
          source: broadcast_source,
          public_methods: %i[subscribed send_alert],
          source_location: '/rails/app/channels/alert_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'detects ActionCable.server.broadcast patterns' do
        units = extractor.extract_all
        expect(units.first.metadata[:broadcasts_to]).to include('alerts')
      end

      it 'detects broadcast_to patterns' do
        units = extractor.extract_all
        expect(units.first.metadata[:broadcasts_to]).to include('broadcast_to:current_user')
      end
    end

    context 'source discovery via convention fallback' do
      let(:channel_source) { "class FallbackChannel < ApplicationCable::Channel\nend\n" }

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'FallbackChannel',
          source: channel_source,
          public_methods: [],
          source_location: nil
        )
        stub_application_cable_channel(base, [@channel])
        stub_rails_root('/rails')
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with('/rails/app/channels/fallback_channel.rb').and_return(true)
      end

      it 'falls back to convention path when source_location is nil' do
        units = extractor.extract_all
        expect(units.first.file_path).to eq('/rails/app/channels/fallback_channel.rb')
      end
    end

    context 'dependency scanning' do
      let(:channel_source) do
        <<~RUBY
          class OrderChannel < ApplicationCable::Channel
            def subscribed
              stream_for current_user
            end

            def update_order(data)
              order = User.find(data['id'])
              NotificationService.call(order)
              OrderMailer.confirmation(order).deliver_later
              ProcessOrderJob.perform_later(order.id)
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'OrderChannel',
          source: channel_source,
          public_methods: %i[subscribed update_order],
          source_location: '/rails/app/channels/order_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'detects model dependencies via ModelNameCache' do
        units = extractor.extract_all
        model_deps = units.first.dependencies.select { |d| d[:type] == :model }
        expect(model_deps.map { |d| d[:target] }).to include('User')
      end

      it 'detects service dependencies' do
        units = extractor.extract_all
        service_deps = units.first.dependencies.select { |d| d[:type] == :service }
        expect(service_deps.map { |d| d[:target] }).to include('NotificationService')
      end

      it 'detects job dependencies' do
        units = extractor.extract_all
        job_deps = units.first.dependencies.select { |d| d[:type] == :job }
        expect(job_deps.map { |d| d[:target] }).to include('ProcessOrderJob')
      end

      it 'detects mailer dependencies' do
        units = extractor.extract_all
        mailer_deps = units.first.dependencies.select { |d| d[:type] == :mailer }
        expect(mailer_deps.map { |d| d[:target] }).to include('OrderMailer')
      end

      it 'includes :via key on all dependencies' do
        units = extractor.extract_all
        units.first.dependencies.each do |dep|
          expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
        end
      end
    end

    context 'ApplicationCable::Channel filtering' do
      before do
        base = stub_action_cable_base
        app_channel = build_mock_channel(
          'ApplicationCable::Channel',
          source: "class ApplicationCable::Channel < ActionCable::Channel::Base\nend\n",
          public_methods: [],
          source_location: '/rails/app/channels/application_cable/channel.rb'
        )
        real_channel = build_mock_channel(
          'ChatChannel',
          source: "class ChatChannel < ApplicationCable::Channel\nend\n",
          public_methods: [],
          source_location: '/rails/app/channels/chat_channel.rb'
        )
        allow(base).to receive(:descendants).and_return([app_channel, real_channel])
      end

      it 'filters out ApplicationCable::Channel' do
        units = extractor.extract_all
        expect(units.map(&:identifier)).to eq(['ChatChannel'])
      end
    end

    context 'anonymous class filtering' do
      before do
        base = stub_action_cable_base
        anon_channel = build_mock_channel(
          nil,
          source: '',
          public_methods: [],
          source_location: nil
        )
        real_channel = build_mock_channel(
          'RealChannel',
          source: "class RealChannel < ApplicationCable::Channel\nend\n",
          public_methods: [],
          source_location: '/rails/app/channels/real_channel.rb'
        )
        allow(base).to receive(:descendants).and_return([anon_channel, real_channel])
      end

      it 'filters out anonymous classes' do
        units = extractor.extract_all
        expect(units.map(&:identifier)).to eq(['RealChannel'])
      end
    end

    context 'namespaced channels' do
      let(:channel_source) do
        <<~RUBY
          module Admin
            class NotificationChannel < ApplicationCable::Channel
              def subscribed
                stream_from "admin_notifications"
              end
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'Admin::NotificationChannel',
          source: channel_source,
          public_methods: %i[subscribed],
          source_location: '/rails/app/channels/admin/notification_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'preserves namespace in identifier' do
        units = extractor.extract_all
        expect(units.first.identifier).to eq('Admin::NotificationChannel')
      end

      it 'extracts namespace' do
        units = extractor.extract_all
        expect(units.first.namespace).to eq('Admin')
      end
    end

    context 'error handling' do
      before do
        base = stub_action_cable_base
        @bad_channel = build_mock_channel(
          'BadChannel',
          source: '',
          public_methods: [],
          source_location: nil
        )
        allow(@bad_channel).to receive(:instance_methods).and_raise(StandardError, 'boom')
        @good_channel = build_mock_channel(
          'GoodChannel',
          source: "class GoodChannel < ApplicationCable::Channel\nend\n",
          public_methods: [],
          source_location: '/rails/app/channels/good_channel.rb'
        )
        stub_application_cable_channel(base, [@bad_channel, @good_channel])
      end

      it 'skips the failing channel and extracts the rest' do
        logger = double('logger', error: nil, info: nil, warn: nil, debug: nil)
        stub_const('Rails', double('Rails', logger: logger, root: Pathname.new('/rails')))
        units = extractor.extract_all
        expect(units.size).to eq(1)
        expect(units.first.identifier).to eq('GoodChannel')
      end

      it 'logs the error' do
        logger = double('logger', error: nil, info: nil, warn: nil, debug: nil)
        stub_const('Rails', double('Rails', logger: logger, root: Pathname.new('/rails')))
        extractor.extract_all
        expect(logger).to have_received(:error).with(/Failed to extract channel BadChannel/)
      end
    end

    context 'empty channel (no methods defined)' do
      let(:channel_source) do
        <<~RUBY
          class EmptyChannel < ApplicationCable::Channel
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'EmptyChannel',
          source: channel_source,
          public_methods: [],
          source_location: '/rails/app/channels/empty_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'extracts successfully with empty actions and streams' do
        units = extractor.extract_all
        expect(units.first.metadata[:actions]).to eq([])
        expect(units.first.metadata[:stream_names]).to eq([])
      end
    end

    context 'LOC metadata' do
      let(:channel_source) do
        <<~RUBY
          class CountChannel < ApplicationCable::Channel
            def subscribed
              stream_from "count"
            end

            # A comment
            def speak(data)
              Message.create!(content: data['message'])
            end
          end
        RUBY
      end

      before do
        base = stub_action_cable_base
        @channel = build_mock_channel(
          'CountChannel',
          source: channel_source,
          public_methods: %i[subscribed speak],
          source_location: '/rails/app/channels/count_channel.rb'
        )
        stub_application_cable_channel(base, [@channel])
      end

      it 'counts non-blank non-comment lines' do
        units = extractor.extract_all
        # Lines: class, def subscribed, stream_from, end, blank, # comment, def speak, Message.create!, end, end
        # Non-blank non-comment: class, def subscribed, stream_from, end, def speak, Message.create!, end, end = 8
        expect(units.first.metadata[:loc]).to eq(8)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  def channel_base_class
    @channel_base_class ||= begin
      klass = Class.new
      klass.define_singleton_method(:descendants) { [] }
      klass
    end
  end

  def stub_action_cable_base
    base = channel_base_class
    stub_const('ActionCable::Channel::Base', base)
    base
  end

  def build_mock_channel(name, source:, public_methods:, source_location:)
    channel = double(name || 'anonymous')
    allow(channel).to receive(:name).and_return(name)
    allow(channel).to receive(:instance_methods).with(false).and_return(public_methods)
    allow(channel).to receive(:methods).with(false).and_return([])
    stub_channel_source_location(channel, source_location)
    stub_channel_file_reading(source_location, source)
    channel
  end

  def stub_channel_source_location(channel, source_location)
    if source_location
      method_double = double('method', source_location: [source_location, 1])
      allow(channel).to receive(:instance_method).and_return(method_double)
    else
      allow(channel).to receive(:instance_method).and_raise(NameError)
    end
  end

  def stub_channel_file_reading(source_location, source)
    allow(File).to receive(:exist?).and_call_original
    return unless source_location

    allow(File).to receive(:exist?).with(source_location).and_return(true)
    allow(File).to receive(:read).with(source_location).and_return(source)
  end

  def stub_application_cable_channel(base, channels)
    app_channel = double('ApplicationCable::Channel')
    allow(app_channel).to receive(:name).and_return('ApplicationCable::Channel')
    all_descendants = channels + [app_channel]
    allow(base).to receive(:descendants).and_return(all_descendants)
  end

  def stub_rails_root(path)
    root = Pathname.new(path)
    allow(Rails).to receive(:root).and_return(root) if defined?(Rails)
    stub_const('Rails', double('Rails', root: root)) unless defined?(Rails)
  end
end
