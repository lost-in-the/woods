# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/extracted_unit'
require 'woods/method_table'
require 'woods/mcp/lookup_member'
require 'woods/mcp/tool_response_renderer'
require 'woods/mcp/renderers/plain_renderer'

# Alternative definitions of one method that a static reading cannot order
# (the bodies of an `if` and its `else`, the branches of a `case`) are listed
# as candidates with a statement that Woods cannot tell which one Ruby calls,
# never as one answer. Sequential redefinition stays one answer.
RSpec.describe Woods::MCP::LookupMember, 'over alternative definitions of one method' do
  let(:path) { 'app/models/alternative.rb' }

  def unit_for(source, type: :model, metadata: {})
    unit = Woods::ExtractedUnit.new(type: type, identifier: 'Alternative', file_path: path)
    unit.source_code = source
    unit.source_identity_lines = source.lines.size
    Woods::MethodTable.record(unit)
    unit.metadata.merge!(metadata)
    JSON.parse(JSON.generate(unit.to_h))
  end

  def answer(unit, identifier = 'Alternative#pick')
    described_class.answer(unit, described_class.parse(identifier))
  end

  # The line of the definition Ruby installs when the source is evaluated
  # with FLAG set to +flag+.
  def installed_line(source, flag, name = :pick)
    namespace = Module.new
    namespace.const_set(:FLAG, flag)
    namespace.module_eval(source, path, 1)
    namespace.const_get(:Alternative).instance_method(name).source_location.last
  end

  def candidate_lines(data)
    data['candidates'].map { |candidate| candidate.dig('member', 'file_line') }
  end

  let(:if_else) { <<~RUBY }
    class Alternative
      if FLAG
        def pick
          :first
        end
      else
        def pick
          :second
        end
      end
    end
  RUBY

  it 'lists the bodies of an if and its else as candidates, either of which Ruby may install' do
    expect([installed_line(if_else, true), installed_line(if_else, false)]).to eq([3, 7])

    data = answer(unit_for(if_else))

    expect(data).not_to have_key('member')
    expect(data).not_to have_key('source_code')
    expect(candidate_lines(data)).to eq([3, 7])
    expect(data['candidates'].map { |candidate| candidate['source_code'] })
      .to eq(["    def pick\n      :first\n    end\n", "    def pick\n      :second\n    end\n"])
    expect(data['candidates']).to all(include('note' => 'defined under a condition'))
    expect(data['statement']).to eq(
      'Alternative#pick: model unit Alternative defines the instance method pick 2 times in its own body ' \
      '(lines 3 and 7 of its published source), under conditions the published source does not settle, ' \
      'so Woods cannot tell which one Ruby calls. Each definition is listed under candidates. ' \
      'It is not a unit of its own; look up Alternative for the whole unit.'
    )
  end

  it 'lists the branches of a case as candidates' do
    source = <<~RUBY
      class Alternative
        case FLAG
        when true
          def pick = :first
        else
          def pick = :second
        end
      end
    RUBY
    expect([installed_line(source, true), installed_line(source, false)]).to eq([4, 6])

    data = answer(unit_for(source))

    expect(data).not_to have_key('member')
    expect(candidate_lines(data)).to eq([4, 6])
    expect(data['statement']).to include('so Woods cannot tell which one Ruby calls')
  end

  it 'lists a definite definition and a later conditional one as candidates' do
    source = <<~RUBY
      class Alternative
        def pick = :plain
        def pick = :override if FLAG
      end
    RUBY
    expect([installed_line(source, true), installed_line(source, false)]).to eq([3, 2])

    data = answer(unit_for(source))

    expect(candidate_lines(data)).to eq([2, 3])
    expect(data['candidates'].map { |candidate| candidate['note'] }).to eq([nil, 'defined under a condition'])
  end

  it 'renders each alternative as a candidate in the plain format' do
    text = Woods::MCP::Renderers::PlainRenderer.new.render_lookup_member(answer(unit_for(if_else)))

    expect(text).to include('Candidate 1: Alternative (defined under a condition)')
    expect(text).to include('Candidate 2: Alternative (defined under a condition)')
    expect(text).to include('cannot tell which one Ruby calls')
  end

  it "answers the alternative the controller extractor recorded from Ruby's own source_location" do
    line = installed_line(if_else, true)
    unit = unit_for(if_else, type: :controller,
                             metadata: { action_sources: { 'pick' => { owner: 'Alternative', defined_in: 'Alternative',
                                                                       file: path, line: line } } })

    data = answer(unit)

    expect(data).not_to have_key('candidates')
    expect(data['member']).to include('file_line' => 3, 'candidate' => 'conditional')
    expect(data['source_code']).to include(':first')
    expect(data['other_definitions'].map { |entry| entry['file_line'] }).to eq([7])
    expect(data['statement']).to include('Ruby installs the definition at line 3 of app/models/alternative.rb, ' \
                                         'as the extractor recorded from the running application (action_sources).')
  end

  it 'keeps the later of two sequential definitions as the one answer' do
    data = answer(unit_for(<<~RUBY))
      class Alternative
        def pick = :first
        def pick = :second
      end
    RUBY

    expect(data).not_to have_key('candidates')
    expect(data['member']).to include('file_line' => 3)
    expect(data['statement']).to eq('Alternative#pick is a public instance method of model unit Alternative, ' \
                                    'defined in its own body. It is not a unit of its own; look up Alternative ' \
                                    'for the whole unit.')
  end

  it 'answers a single definition exactly as before' do
    data = answer(unit_for("class Alternative\n  def pick\n    :only\n  end\nend\n"))

    expect(JSON.generate(data)).to eq(JSON.generate(
                                        'identifier' => 'Alternative#pick',
                                        'member_of' => { 'identifier' => 'Alternative', 'type' => 'model',
                                                         'file_path' => path },
                                        'member' => { 'name' => 'pick', 'kind' => 'instance', 'line' => 2,
                                                      'end_line' => 4, 'visibility' => 'public',
                                                      'owner' => 'Alternative', 'file_line' => 2,
                                                      'file_end_line' => 4 },
                                        'statement' => 'Alternative#pick is a public instance method of model ' \
                                                       'unit Alternative, defined in its own body. It is not a ' \
                                                       'unit of its own; look up Alternative for the whole unit.',
                                        'source_code' => "  def pick\n    :only\n  end\n"
                                      ))
  end

  it 'answers a lone conditional definition with a caveat that Ruby may not define it there' do
    data = answer(unit_for("class Alternative\n  if FLAG\n    def pick = :only\n  end\nend\n"))

    expect(data['member']).to include('file_line' => 3)
    expect(data['caveats']).to eq(['The definition at line 3 of the published source is under a condition, so ' \
                                   'Ruby may not define pick there.'])
  end
end
