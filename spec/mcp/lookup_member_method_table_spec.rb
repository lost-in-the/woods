# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/method_table'
require 'woods/mcp/lookup_member'

# A member lookup over a unit whose method table was built from its source:
# `Owner.a` and `Owner#a` name the definition Ruby calls, with the
# visibility Ruby reports, and no dead definition of the same name is left
# beside it to be chosen instead.
RSpec.describe Woods::MCP::LookupMember, 'over a method table built from source' do
  def unit_for(identifier, source)
    unit = Woods::ExtractedUnit.new(type: :poro, identifier: identifier, file_path: 'app/models/sample.rb')
    unit.source_code = source
    Woods::MethodTable.record(unit)
    JSON.parse(JSON.generate(unit.to_h))
  end

  def member(unit, identifier)
    answer = described_class.answer(unit, described_class.parse(identifier))
    expect(answer).not_to have_key('other_definitions')
    answer['member'].values_at('line', 'visibility')
  end

  it 'answers the module function copy that replaced an earlier singleton method' do
    unit = unit_for('Util', <<~RUBY)
      module Util
        def a; end
        private_class_method def self.a; end
        module_function :a
      end
    RUBY

    expect(member(unit, 'Util.a')).to eq([2, 'public'])
    expect(member(unit, 'Util#a')).to eq([2, 'private'])
  end

  it 'answers a singleton method defined after module_function, and the instance side it left' do
    unit = unit_for('Util', <<~RUBY)
      module Util
        def a; end
        module_function :a
        def self.a; end
      end
    RUBY

    expect(member(unit, 'Util.a')).to eq([4, 'public'])
    expect(member(unit, 'Util#a')).to eq([2, 'private'])
  end

  it 'answers an instance method redefined after module_function, and the copy it left' do
    unit = unit_for('Util', <<~RUBY)
      module Util
        def a; end
        module_function :a
        def a; end
      end
    RUBY

    expect(member(unit, 'Util#a')).to eq([4, 'public'])
    expect(member(unit, 'Util.a')).to eq([2, 'public'])
  end

  it 'answers the later of two definitions on one side, with its own visibility' do
    unit = unit_for('Account', <<~RUBY)
      class Account
        def a; end
        private :a
        def a; end
        def self.b; end
        private_class_method :b
        def self.b; end
      end
    RUBY

    expect(member(unit, 'Account#a')).to eq([4, 'public'])
    expect(member(unit, 'Account.b')).to eq([7, 'public'])
  end
end
