# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/poro_extractor'
require 'woods/extractors/lib_extractor'

RSpec.describe 'Owner-specific parent extraction (#474)' do
  include_context 'extractor setup'

  {
    poro: [Woods::Extractors::PoroExtractor, 'app/models', :extract_poro_file],
    lib: [Woods::Extractors::LibExtractor, 'lib', :extract_lib_file]
  }.each do |type, (extractor_class, directory, method)|
    describe type do
      def assert_parent(unit, expected)
        expect(unit).not_to be_nil
        expect(unit.identifier).to eq('Billing::PlanChange')
        expect(unit.metadata[:parent_class]).to eq(expected)
        expect(unit.source_code).to include("Parent: #{expected || 'none'}")
      end

      it 'does not borrow the parent of a nested error class' do
        path = create_file("#{directory}/billing/plan_change.rb", <<~RUBY)
          module Billing
            class PlanChange
              class Error < StandardError
              end
            end
          end
        RUBY
        assert_parent(extractor_class.new.public_send(method, path), nil)
      end

      it 'preserves the explicit textual parent of a compact qualified declaration' do
        path = create_file("#{directory}/billing/plan_change.rb", <<~RUBY)
          class Billing::PlanChange < ::Vendor::Base
            class Error < StandardError
            end
          end
        RUBY
        assert_parent(extractor_class.new.public_send(method, path), '::Vendor::Base')
      end

      it 'does not borrow a later sibling parent' do
        path = create_file("#{directory}/billing/plan_change.rb", <<~RUBY)
          module Billing
            class PlanChange
            end
            class Other < StandardError
            end
          end
        RUBY
        assert_parent(extractor_class.new.public_send(method, path), nil)
      end

      it 'ignores declaration text in comments, strings, and heredocs' do
        path = create_file("#{directory}/billing/plan_change.rb", <<~RUBY)
          module Billing
            class PlanChange
              # class Pretend < CommentParent
              TEXT = "
          class Billing::PlanChange < StringParent
          end
          "
              MORE = <<~TEXT
          class Billing::PlanChange < HeredocParent
          end
          TEXT
            end
          end
        RUBY
        assert_parent(extractor_class.new.public_send(method, path), nil)
      end

      it 'does not report a constant prefix from a dynamic parent expression' do
        path = create_file("#{directory}/billing/plan_change.rb", <<~RUBY)
          class Billing::PlanChange < ParentFactory.call
            class Error < StandardError
            end
          end
        RUBY
        assert_parent(extractor_class.new.public_send(method, path), nil)
      end

      it 'preserves the unit but declines parent metadata for unparseable source' do
        path = create_file("#{directory}/billing/plan_change.rb", "class Billing::PlanChange < Base\n")
        assert_parent(extractor_class.new.public_send(method, path), nil)
      end
    end
  end

  it 'selects the governed class inside an inheriting namespace wrapper' do
    path = create_file('app/models/billing/container/plan_change.rb', <<~RUBY)
      module Billing
        class Container < WrapperBase
          class PlanChange
            class Error < StandardError
            end
          end
        end
      end
    RUBY
    unit = Woods::Extractors::PoroExtractor.new.extract_poro_file(path)
    expect(unit.identifier).to eq('Billing::Container::PlanChange')
    expect(unit.metadata[:parent_class]).to be_nil
    expect(unit.source_code).to include('Parent: none')
  end

  it 'selects a governed declaration after an inheriting sibling' do
    path = create_file('app/models/billing/plan_change.rb', <<~RUBY)
      module Billing
        class Other < WrongParent
        end
        class PlanChange < ExpectedParent
        end
      end
    RUBY
    unit = Woods::Extractors::PoroExtractor.new.extract_poro_file(path)
    expect(unit.identifier).to eq('Billing::PlanChange')
    expect(unit.metadata[:parent_class]).to eq('ExpectedParent')
    expect(unit.source_code).to include('Parent: ExpectedParent')
  end
end
