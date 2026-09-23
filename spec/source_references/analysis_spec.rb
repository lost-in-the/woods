# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/source_references/collector'
require 'woods/source_references/registry'

RSpec.describe 'Collected source reference resolution' do
  %i[prism parser].each do |backend|
    context "with #{backend}" do
      it 'resolves the reported PORO and callback shapes without executing their bodies' do
        stub_const('RefDomain', Module.new)
        RefDomain.const_set(:PlanChange, Class.new)
        stub_const('RefToken', Class.new)
        stub_const('RefCaller', Class.new)
        RefToken.define_singleton_method(:generate) { raise 'not an execution trace' }
        files = {
          '/app/caller.rb' => <<~RUBY_SOURCE,
            class RefCaller
              before_validation { self.token = RefToken.generate }
              def execute(account)
                RefDomain::PlanChange.new(account).execute
              end
              # RefToken is also discussed in comments and plain text.
              LABEL = 'RefDomain::PlanChange'
              class Helper
                def call
                  RefToken.generate
                end
              end
            end
          RUBY_SOURCE
          '/app/plan_change.rb' => 'module RefDomain; class PlanChange; end; end',
          '/app/token.rb' => 'class RefToken; end'
        }
        units = [
          Woods::ExtractedUnit.new(type: :model, identifier: 'RefCaller', file_path: '/app/caller.rb'),
          Woods::ExtractedUnit.new(type: :poro, identifier: 'RefDomain::PlanChange', file_path: '/app/plan_change.rb'),
          Woods::ExtractedUnit.new(type: :poro, identifier: 'RefToken', file_path: '/app/token.rb')
        ]
        collector = Woods::SourceReferences::Collector.new(backend: backend)
        sources = files.transform_values { |source| collector.call(source) }
        registry = Woods::SourceReferences::Registry.new(units: units, sources: sources, root: '/app')
        records = sources.fetch('/app/caller.rb').fetch('references')
        resolved = records.filter_map { |record| registry.resolve(record, file_path: '/app/caller.rb') }

        expect(resolved).to contain_exactly(
          { type: :poro, target: 'RefToken', via: :code_reference },
          { type: :poro, target: 'RefDomain::PlanChange', via: :code_reference }
        )
        expect(records.count { |record| record['owner'] == 'RefCaller::Helper' }).to eq(1)
      end
    end
  end
end
