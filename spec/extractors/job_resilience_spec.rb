# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extractors/job_resilience'

RSpec.describe Woods::Extractors::JobResilience do
  describe '.static' do
    it 'reads only real class-body declarations, never a comment or a string (woods#754)' do
      facts = described_class.static(<<~RUBY, 'NotifySubscribersJob')
        # Deliberately declares no retry_on or discard_on, so an exception in the
        # mailer loses the notification.
        class NotifySubscribersJob < ApplicationJob
          DOC = "retry_on Timeout::Error"
          def perform(post_id) = Post.find(post_id)
        end
      RUBY

      expect(facts).to eq(retry_on: [], discard_on: [], rescue_from: [], around_perform: [], rescue_handlers: [],
                          resilience_source: 'static')
    end

    it 'publishes each declaration with its exceptions, literal options and owner' do
      facts = described_class.static(<<~RUBY, 'SyncJob')
        class SyncJob < ApplicationJob
          retry_on Net::OpenTimeout, ::Timeout::Error, wait: 5.seconds, attempts: 3
          discard_on ActiveJob::DeserializationError do |job, error|
            Rails.logger.warn(error)
          end
          rescue_from Faraday::Error, with: :report
          rescue_from(KeyError) { |error| raise }
          around_perform :with_lock
          around_perform do |job, block|
            block.call
          end
        end
      RUBY

      expect(facts[:retry_on]).to eq(['Net::OpenTimeout', 'Timeout::Error'])
      expect(facts[:discard_on]).to eq(['ActiveJob::DeserializationError'])
      expect(facts[:rescue_handlers].first)
        .to eq(kind: 'retry_on', exceptions: ['Net::OpenTimeout', 'Timeout::Error'], wait: '5.seconds', attempts: 3,
               block: false, declared_in: 'SyncJob')
      expect(facts[:rescue_from]).to eq([
                                          { kind: 'rescue_from', exceptions: ['Faraday::Error'], with: 'report',
                                            declared_in: 'SyncJob' },
                                          { kind: 'rescue_from', exceptions: ['KeyError'], block: true,
                                            declared_in: 'SyncJob' }
                                        ])
      expect(facts[:around_perform]).to eq([{ method: 'with_lock', block: false, declared_in: 'SyncJob' },
                                            { method: nil, block: true, declared_in: 'SyncJob' }])
    end

    it 'lists job callbacks from calls, not from comments' do
      callbacks = described_class.static_callbacks(<<~RUBY)
        class SyncJob < ApplicationJob
          # before_perform :not_a_callback
          before_perform :load_record
          after_enqueue { |job| track(job) }
        end
      RUBY
      expect(callbacks).to eq([{ type: 'before_perform', method: 'load_record' },
                               { type: 'after_enqueue', method: nil }])
    end

    it 'answers empty facts for source that does not parse' do
      expect(described_class.static('class Broken <', 'Broken')[:rescue_handlers]).to eq([])
    end
  end

  describe '.runtime' do
    # Active Job's retry_on and discard_on build their rescue_from handlers
    # inside active_job/exceptions.rb; these fakes do the same in a file of
    # that name, closing over the same locals, so classification and option
    # reading run against the real shapes without loading Active Job.
    let(:gem_dir) { Dir.mktmpdir('activejob') }
    let(:exceptions_file) do
      path = File.join(gem_dir, 'lib', 'active_job', 'exceptions.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        module ActiveJob
          module Exceptions
            def retry_on(*exceptions, wait: 3, attempts: 5, queue: nil, priority: nil, &block)
              rescue_from(*exceptions) do |error|
                retry_job
              end
            end

            def discard_on(*exceptions, &block)
              rescue_from(*exceptions) do |error|
                instrument :discard
              end
            end
          end
        end
      RUBY
      path
    end

    after { FileUtils.remove_entry(gem_dir) }

    def retry_handler(wait: 3, attempts: 5, queue: nil, priority: nil, block: nil)
      handler = proc { [wait, attempts, queue, priority, block] }
      allow(handler).to receive(:source_location).and_return([exceptions_file, 5])
      handler
    end

    def discard_handler(block: nil)
      handler = proc { block }
      allow(handler).to receive(:source_location).and_return([exceptions_file, 11])
      handler
    end

    def job(name, handlers, superclass: Object, callbacks: [])
      klass = Class.new(superclass)
      klass.define_singleton_method(:name) { name }
      klass.define_singleton_method(:rescue_handlers) { handlers }
      klass.define_singleton_method(:_perform_callbacks) { callbacks }
      klass
    end

    it 'classifies handlers by the method that made them and reads retry options without calling them' do
      inherited = retry_handler(wait: 10, attempts: 3)
      base = job('ApplicationJob', [['ActiveRecord::Deadlocked', inherited]])
      discard = discard_handler
      own = job('SyncJob', [['ActiveRecord::Deadlocked', inherited], ['KeyError', discard],
                            ['Faraday::Error', :report], ['TypeError', proc { :custom }]], superclass: base)

      facts = described_class.runtime(own, root: '/app')

      expect(facts[:rescue_handlers]).to eq(
        [{ kind: 'retry_on', exceptions: ['ActiveRecord::Deadlocked'], wait: 10, attempts: 3,
           block: false, declared_in: 'ApplicationJob' },
         { kind: 'discard_on', exceptions: ['KeyError'], block: false, declared_in: 'SyncJob' },
         { kind: 'rescue_from', exceptions: ['Faraday::Error'], with: 'report', declared_in: 'SyncJob' },
         { kind: 'rescue_from', exceptions: ['TypeError'], block: true, declared_in: 'SyncJob' }]
      )
      expect(facts).to include(retry_on: ['ActiveRecord::Deadlocked'], discard_on: ['KeyError'],
                               resilience_source: 'runtime')
    end

    it 'groups the exceptions one declaration registered' do
      handler = retry_handler(wait: :polynomially_longer, attempts: :unlimited)
      facts = described_class.runtime(job('SyncJob', [['A', handler], ['B', handler]]), root: '/app')
      expect(facts[:rescue_handlers]).to eq([{ kind: 'retry_on', exceptions: %w[A B], wait: 'polynomially_longer',
                                               attempts: 'unlimited', block: false, declared_in: 'SyncJob' }])
    end

    it 'publishes empty arrays for a job that declares nothing' do
      facts = described_class.runtime(job('NotifySubscribersJob', []), root: '/app')
      expect(facts.values_at(:retry_on, :discard_on, :rescue_from, :around_perform, :rescue_handlers)).to all(eq([]))
    end

    it 'keeps only around_perform callbacks the application defines' do
      app_proc = proc {}
      framework_proc = proc {}
      allow(app_proc).to receive(:source_location).and_return(['/app/app/jobs/sync_job.rb', 4])
      allow(framework_proc).to receive(:source_location).and_return(['/gems/activejob/lib/active_job/timezones.rb', 8])
      callbacks = [double(kind: :around, filter: framework_proc), double(kind: :around, filter: app_proc),
                   double(kind: :before, filter: app_proc)]
      facts = described_class.runtime(job('SyncJob', [], callbacks: callbacks), root: '/app')
      expect(facts[:around_perform]).to eq([{ method: nil, block: true, declared_in: 'SyncJob' }])
    end
  end
end
