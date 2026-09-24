# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/mcp/index_reader'

RSpec.describe 'whole-extractor failure reporting' do
  include_context 'published extraction failure fixture'

  [nil, Object.new].each do |absent|
    it "preserves an intentionally #{absent.nil? ? 'absent' : 'unsupported'} consumer without inventing a failure" do
      allow(schedule_class).to receive(:new).and_return(absent)

      expect { extractor.refresh(:scheduled_jobs) }.not_to raise_error
      expect_previous_publication
    end
  end

  %i[full concurrent incremental refresh].each do |mode|
    context "during #{mode} extraction" do
      def run_mode(mode)
        case mode
        when :full, :concurrent then extractor.extract_all
        when :incremental then extractor.extract_changed(changed_paths)
        when :refresh then extractor.refresh(:routes, :scheduled_jobs)
        end
      end

      before { Woods.configuration.concurrent_extraction = mode == :concurrent }

      %i[extraction construction].each do |failure|
        it "refuses publication after a pre-mutation #{failure} error even with a successful sibling, then retries" do
          target, method = failure == :extraction ? [schedule_consumer, :extract_all] : [schedule_class, :new]
          if failure == :extraction
            allow(target).to receive(method).and_raise(IOError, 'schedule unavailable')
          else
            allow(target).to receive(method).and_raise(IOError, 'schedule initialization failed')
          end

          expect { run_mode(mode) }.to raise_error(StandardError, /schedule|scheduled_jobs/)
          expect(route_consumer).to have_received(:extract_all).at_least(:twice)
          expect_previous_publication

          if failure == :extraction
            allow(target).to receive(method) { [fixture_unit(:scheduled_job, 'scheduled:fixture', changed_paths.last)] }
          else
            allow(target).to receive(method).and_return(schedule_consumer)
          end
          run_mode(mode)
          extractor.raise_on_publication_failure!
          expect_complete_retry
        end
      end
    end
  end
end
