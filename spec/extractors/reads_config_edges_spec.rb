# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractor'

# Every extractor that scans Ruby source links a unit to the configuration
# files its source reads. One example per file-based entry point, so an
# extractor that drops the scan fails here by name.
RSpec.describe 'reads_config edges across extractors' do
  include_context 'extractor setup'

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.settings_readers = [{ constant: 'Settings', file: 'config/settings.yml' }]
    example.run
  ensure
    Woods.configuration = original
  end

  before { stub_const('ActiveRecord::Base', double('ActiveRecord::Base', descendants: [])) }

  let(:edges) do
    [{ type: :config_file, target: 'config/rates.yml', via: :reads_config },
     { type: :config_file, target: 'config/settings.yml', via: :reads_config }]
  end

  def body
    "  def call\n    Rails.application.config_for(:rates)\n    Settings.payments.api_host\n  end\n"
  end

  def config_edges(units)
    Array(units).compact.flat_map(&:dependencies).select { |edge| edge[:type] == :config_file }
  end

  {
    services: ['app/services/ledger_service.rb', :extract_service_file, 'class LedgerService'],
    jobs: ['app/jobs/ledger_job.rb', :extract_job_file, 'class LedgerJob < ApplicationJob'],
    policies: ['app/policies/ledger_policy.rb', :extract_policy_file, 'class LedgerPolicy'],
    pundit_policies: ['app/policies/widget_policy.rb', :extract_pundit_file,
                      "class WidgetPolicy < ApplicationPolicy\n  def show? = true"],
    validators: ['app/validators/ledger_validator.rb', :extract_validator_file,
                 'class LedgerValidator < ActiveModel::Validator'],
    serializers: ['app/serializers/ledger_serializer.rb', :extract_serializer_file,
                  'class LedgerSerializer < ActiveModel::Serializer'],
    managers: ['app/managers/ledger_manager.rb', :extract_manager_file, 'class LedgerManager < SimpleDelegator'],
    decorators: ['app/decorators/ledger_decorator.rb', :extract_decorator_file, 'class LedgerDecorator'],
    concerns: ['app/models/concerns/ledgerable.rb', :extract_concern_file,
               "module Ledgerable\n  extend ActiveSupport::Concern"],
    libs: ['lib/ledger_client.rb', :extract_lib_file, 'class LedgerClient'],
    configurations: ['config/initializers/ledger.rb', :extract_configuration_file, 'class LedgerBoot']
  }.each do |key, (relative, method_name, opening)|
    it "links a #{key} unit to the config files its source reads" do
      path = create_file(relative, "#{opening}\n#{body}end\n")

      units = Woods::Extractor::EXTRACTORS.fetch(key).new.public_send(method_name, path)

      expect(config_edges(units)).to eq(edges)
    end
  end
end
