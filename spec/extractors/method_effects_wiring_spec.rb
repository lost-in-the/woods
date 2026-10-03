# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/extractors/service_extractor'
require 'woods/extractors/job_extractor'
require 'woods/extractors/manager_extractor'
require 'woods/extractors/poro_extractor'

# Each file-based extractor hands its unit to MethodEffects after the
# dependencies are known, so the method map and the edge annotation agree.
#
# Deliberately loads the extractors alone, as their own specs do: Woods's
# entry point (and so Woods.configuration) is absent here.
RSpec.describe Woods::Extractors::MethodEffects, 'extractor wiring' do
  include_context 'extractor setup'

  def through_of(unit, type, target, via)
    edge = unit.dependencies.find { |dep| dep[:type] == type && dep[:target] == target && dep[:via] == via }
    edge && edge[:through]
  end

  it 'records service methods and names them on the edges' do
    path = create_file('app/services/shipment_service.rb', <<~RUBY)
      class ShipmentService
        def dispatch(shipment)
          LabelJob.perform_later(shipment.id)
          ShipmentMailer.dispatched(shipment).deliver_later
        end

        def quote(shipment)
          RateService.call(shipment)
        end
      end
    RUBY

    unit = Woods::Extractors::ServiceExtractor.new.extract_service_file(path)

    expect(unit.metadata[:method_effects].keys).to eq(%w[dispatch quote])
    expect(unit.metadata[:method_effects]['dispatch'])
      .to include(jobs_enqueued: ['LabelJob'], mail_sent: ['ShipmentMailer'])
    expect(through_of(unit, :job, 'LabelJob', :job_enqueue)).to eq('dispatch')
    expect(through_of(unit, :job, 'LabelJob', :code_reference)).to be_nil
    expect(through_of(unit, :mailer, 'ShipmentMailer', :code_reference)).to eq('dispatch')
    expect(through_of(unit, :service, 'RateService', :code_reference)).to eq('quote')
  end

  it 'keeps the dependency list of a service the same size' do
    source = <<~RUBY
      class ShipmentService
        def dispatch(shipment)
          LabelJob.perform_later(shipment.id)
        end
      end
    RUBY
    path = create_file('app/services/shipment_service.rb', source)
    extractor = Woods::Extractors::ServiceExtractor.new

    unit = extractor.extract_service_file(path)

    expect(unit.dependencies.map { |dep| dep.except(:through) }).to eq(extractor.send(:extract_dependencies, source))
  end

  it 'records a job perform and the jobs it chains' do
    path = create_file('app/jobs/label_job.rb', <<~RUBY)
      class LabelJob < ApplicationJob
        def perform(shipment_id)
          print_label(shipment_id)
        end

        private

        def print_label(shipment_id)
          ManifestJob.perform_later(shipment_id)
        end
      end
    RUBY

    unit = Woods::Extractors::JobExtractor.new.extract_job_file(path)

    expect(unit.metadata[:method_effects]).to eq(
      'perform' => {
        jobs_enqueued: [], mail_sent: [], services_called: [], columns_written: [], events_published: [],
        external_calls: [], via_method: { 'print_label' => { jobs_enqueued: ['ManifestJob'] } }
      }
    )
    expect(through_of(unit, :job, 'ManifestJob', :job_enqueue)).to eq('perform')
  end

  it 'records manager methods' do
    path = create_file('app/managers/shipment_manager.rb', <<~RUBY)
      class ShipmentManager < SimpleDelegator
        def release!
          ReleaseJob.perform_later(id)
        end
      end
    RUBY

    unit = Woods::Extractors::ManagerExtractor.new.extract_manager_file(path)

    expect(unit.metadata[:method_effects].keys).to eq(['release!'])
    expect(through_of(unit, :job, 'ReleaseJob', :job_enqueue)).to eq('release!')
  end

  it 'records plain Ruby object methods' do
    stub_const('ActiveRecord::Base', Class.new { def self.descendants = [] })
    path = create_file('app/models/shipment_tally.rb', <<~RUBY)
      class ShipmentTally
        def flush!
          TallyJob.perform_later
        end
      end
    RUBY

    unit = Woods::Extractors::PoroExtractor.new.extract_poro_file(path)

    expect(unit.metadata[:method_effects].keys).to eq(['flush!'])
    expect(through_of(unit, :job, 'TallyJob', :job_enqueue)).to eq('flush!')
  end

  it 'adds no metadata key to a unit without method effects' do
    path = create_file('app/services/rate_service.rb', <<~RUBY)
      class RateService
        def call(shipment)
          shipment.weight * 2
        end
      end
    RUBY

    unit = Woods::Extractors::ServiceExtractor.new.extract_service_file(path)

    expect(unit.metadata).not_to have_key(:method_effects)
    expect(unit.metadata).not_to have_key(:method_effects_truncated)
  end
end
