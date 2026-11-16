# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

# Each machine fires its event, so the jobs its callbacks enqueued are the
# oracle for the side effects its transition callback publishes.
RSpec.describe 'Transition callback side effects of the body Ruby dispatches', :booted_app do
  before(:all) do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', 'spec/fixtures/transition_callback_forms/boot.rb')
    raise "#{stdout}\n#{stderr}" unless status.success?

    @machines = JSON.parse(stdout.lines.last).fetch('machines')
  end

  def machine(name)
    @machines.fetch(name)
  end

  {
    'RedefinedMachine' => ['a method redefined later in the class', %w[SecondStampJob],
                           %w[app/models/redefined_machine.rb]],
    'PrependedMachine' => ['a prepended override', %w[OverrideStampJob], %w[app/models/concerns/stamp_override.rb]],
    'ChainedMachine' => ['a prepended override calling super', %w[ChainStampJob LocalStampJob],
                         %w[app/models/concerns/stamp_chain.rb app/models/chained_machine.rb]],
    'SiblingMachine' => ['a same-named method in a class earlier in the file', %w[SiblingStampJob],
                         %w[app/models/sibling_machine.rb]],
    'PlainMachine' => ['a method the class defines once', %w[PlainStampJob], %w[app/models/plain_machine.rb]],
    'ConcernMachine' => ['a method an included concern defines', %w[ConcernStampJob],
                         %w[app/models/concerns/concern_stamp.rb]]
  }.each do |name, (description, jobs, files)|
    it "publishes what Ruby enqueues for #{description}" do
      expect(machine(name)['ran']).to eq(jobs)
      expect(machine(name)['published']).to eq(jobs.sort)
      expect(machine(name)['sites']).to eq(files)
    end
  end

  it 'leaves a block callback unanalysed' do
    expect(machine('BlockMachine')['ran']).to eq(%w[BlockStampJob])
    expect(machine('BlockMachine')).to include('block' => true, 'unanalysed' => 'block', 'published' => nil)
  end
end
