# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/container_attribution'

RSpec.describe Woods::ContainerAttribution do
  def unit(type, metadata = {})
    Woods::ExtractedUnit.new(type: type, identifier: "#{type.to_s.capitalize}Unit", file_path: nil).tap do |u|
      u.metadata = metadata
    end
  end

  describe '.for' do
    it 'places controllers, views, components and routes in the web process' do
      %i[controller view_template component view_component route middleware helper graphql_type].each do |type|
        expect(described_class.for(unit(type))).to eq(kind: 'web')
      end
    end

    it 'places a job in the job runner with its queue, naming the adapter only when the class overrides it' do
      expect(described_class.for(unit(:job, queue: :mailers, job_type: :active_job)))
        .to eq(kind: 'jobs', queue: 'mailers')
      expect(described_class.for(unit(:job, queue: 'default', job_type: :active_job, queue_adapter: :async)))
        .to eq(kind: 'jobs', queue: 'default', adapter: 'async')
    end

    it 'names Sidekiq as the adapter of a native Sidekiq worker' do
      expect(described_class.for(unit(:job, queue: 'bulk', job_type: :sidekiq)))
        .to eq(kind: 'jobs', queue: 'bulk', adapter: 'sidekiq')
    end

    it 'places a mailer in the job runner with its delivery method' do
      expect(described_class.for(unit(:mailer, delivery_method: :smtp))).to eq(kind: 'jobs', delivery: 'smtp')
      expect(described_class.for(unit(:scheduled_job))).to eq(kind: 'jobs')
    end

    it 'places models and tables in their database' do
      expect(described_class.for(unit(:model, database: :primary))).to eq(kind: 'database', database: 'primary')
      expect(described_class.for(unit(:database_table, database: 'billing')))
        .to eq(kind: 'database', database: 'billing')
      expect(described_class.for(unit(:database_view))).to eq(kind: 'database')
    end

    it 'marks code every process loads as shared, and rake tasks as tasks' do
      %i[concern service poro lib manager serializer validator decorator policy pundit_policy].each do |type|
        expect(described_class.for(unit(type))).to eq(kind: 'shared')
      end
      expect(described_class.for(unit(:rake_task))).to eq(kind: 'tasks')
    end

    it 'gives framework, test, documentation and configuration units no container' do
      %i[rails_source gem_source test_mapping test_support factory doc configuration config_file engine
         package migration i18n route_file external_consumer caching].each do |type|
        expect(described_class.for(unit(type))).to be_nil
      end
    end
  end

  describe '.annotate' do
    it 'sets metadata[:container], and deletes it when the type has none' do
      job = unit(:job, queue: 'default', job_type: :active_job)
      described_class.annotate(job)
      expect(job.metadata[:container]).to eq(kind: 'jobs', queue: 'default')

      stale = unit(:rails_source, container: { kind: 'web' })
      described_class.annotate(stale)
      expect(stale.metadata).not_to have_key(:container)
    end
  end
end
