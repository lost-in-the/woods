# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'active_support/concern'
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

  def unit_for(source, type: :model, metadata: {}, identity_lines: source.lines.size)
    unit = Woods::ExtractedUnit.new(type: type, identifier: 'Alternative', file_path: path)
    unit.source_code = source
    unit.source_identity_lines = identity_lines
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

  # The published source of Alternative with +concern+ (module Choosing)
  # inlined as a commented block.
  def includer_of(concern)
    framed = concern.lines.map { |line| "  # #{line.rstrip}" }.join("\n")
    <<~RUBY
      class Alternative
      end
      # ┌─────────────────────────────────────────────────────────────────────┐
      # │ Included from: #{'Choosing'.ljust(54)}│
      # └─────────────────────────────────────────────────────────────────────┘
      #{framed}
      # ─────────────────────────── End Choosing ───────────────────────────
    RUBY
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

  # A concern's `class_methods do` body is read as the method table reads
  # any body: its conditional and wrapped definitions are class methods of
  # the including class.
  describe 'in the class_methods block of an inlined concern' do
    let(:concern) { <<~RUBY }
      module Choosing
        extend ActiveSupport::Concern
        class_methods do
          def self.memoize(name) = name
          if FLAG
            def pick = :first
          else
            def pick = :second
          end
          memoize def wrapped = :kept
        end
      end
    RUBY

    let(:includer) { includer_of(concern) }

    # The concern line of the class method Ruby gives the includer when
    # FLAG is +flag+.
    def includer_line(flag, name)
      namespace = Module.new
      namespace.const_set(:FLAG, flag)
      namespace.module_eval(concern, 'choosing.rb', 1)
      Class.new.include(namespace::Choosing).method(name).source_location.last
    end

    it 'lists conditional definitions as candidates of the including class' do
      expect([includer_line(true, :pick), includer_line(false, :pick)]).to eq([6, 8])

      data = answer(unit_for(includer, identity_lines: 2), 'Alternative.pick')

      expect(data).not_to have_key('member')
      expect(data['candidates'].map { |candidate| candidate['member'].values_at('file_unit', 'file_line') })
        .to eq([['Choosing', 6], ['Choosing', 8]])
      expect(data['statement']).to include('concern Choosing, inlined into model unit Alternative,')
    end

    it 'answers a definition passed to a call as a class method of the including class' do
      expect(includer_line(true, :wrapped)).to eq(10)

      data = answer(unit_for(includer, identity_lines: 2), 'Alternative.wrapped')

      expect(data['member']).to include('kind' => 'singleton', 'file_unit' => 'Choosing', 'file_line' => 10)
    end
  end

  # A controller's concerns are not written in include order, but the
  # alternatives of one concern's body are still that body's.
  describe 'in the body of the one inlined concern of a controller' do
    let(:concern) { <<~RUBY }
      module Choosing
        extend ActiveSupport::Concern
        if FLAG
          def pick = :first
        else
          def pick = :second
        end
        def kept = :kept
      end
    RUBY

    def includer_line(flag, name)
      namespace = Module.new
      namespace.const_set(:FLAG, flag)
      namespace.module_eval(concern, 'choosing.rb', 1)
      Class.new.include(namespace::Choosing).instance_method(name).source_location.last
    end

    it 'lists the alternatives of the concern as candidates' do
      expect([includer_line(true, :pick), includer_line(false, :pick)]).to eq([4, 6])

      data = answer(unit_for(includer_of(concern), type: :controller, identity_lines: 2))

      expect(data).not_to have_key('member')
      expect(data['candidates'].map { |candidate| candidate['member'].values_at('file_unit', 'file_line') })
        .to eq([['Choosing', 4], ['Choosing', 6]])
      expect(data).not_to have_key('other_definitions')
      expect(data['statement']).to include('concern Choosing, inlined into controller unit Alternative,')
    end

    it 'answers a single definition of the concern as the member' do
      data = answer(unit_for(includer_of(concern), type: :controller, identity_lines: 2), 'Alternative#kept')

      expect(data['member']).to include('file_unit' => 'Choosing', 'file_line' => 8)
      expect(data).not_to have_key('candidates')
    end
  end

  # Ruby runs the later of two definitions on one line last; a sort by line
  # alone leaves their order to chance.
  describe 'with a definite and a conditional definition on one line' do
    let(:one_line) { 'def pick = :plain; def pick = :conditional if FLAG' }

    def evaluated(source, flag)
      namespace = Module.new
      namespace.const_set(:FLAG, flag)
      namespace.module_eval(source, path, 1)
      namespace.const_get(:Alternative).new.pick
    end

    it 'lists both as candidates of the own body, the definite one first' do
      source = "class Alternative\n  #{one_line}\nend\n"
      expect([evaluated(source, true), evaluated(source, false)]).to eq(%i[conditional plain])

      data = answer(unit_for(source))

      expect(data).not_to have_key('member')
      expect(data['candidates'].map { |candidate| [candidate.dig('member', 'file_line'), candidate['note']] })
        .to eq([[2, nil], [2, 'defined under a condition']])
    end

    it 'lists both as candidates of an inlined concern' do
      concern = "module Choosing\n  #{one_line}\nend\n"
      data = answer(unit_for(includer_of(concern), identity_lines: 2))

      expect(data).not_to have_key('member')
      expect(data['candidates'].map { |candidate| [candidate.dig('member', 'file_line'), candidate['note']] })
        .to eq([[2, nil], [2, 'defined under a condition']])
    end

    it 'lists two bodies that start on one line in source order' do
      source = <<~RUBY
        class Alternative
          if FLAG then def pick = :first else def pick
            :second
          end end
        end
      RUBY
      expect([evaluated(source, true), evaluated(source, false)]).to eq(%i[first second])

      data = answer(unit_for(source))

      expect(data['candidates'].map { |candidate| candidate.dig('member', 'end_line') }).to eq([2, 4])
    end
  end

  # Alternatives that Ruby may all skip leave the next definition callable:
  # it is named as the fallback, never as overridden. Alternatives that
  # cover every branch (an `if` with an `else`) replace it.
  describe 'with a definition the alternatives may leave in place' do
    let(:parent) { "class Parent\n  def pick = :parent\nend\n" }

    def service(identifier, source, parent: nil)
      unit = Woods::ExtractedUnit.new(type: :service, identifier: identifier, file_path: "app/#{identifier}.rb")
      unit.source_code = source
      Woods::MethodTable.record(unit)
      unit.metadata[:parent_class] = parent if parent
      JSON.parse(JSON.generate(unit.to_h))
    end

    def child_answer(child)
      units = { 'Child' => service('Child', child, parent: 'Parent'), 'Parent' => service('Parent', parent) }
      described_class.answer(units['Child'], described_class.parse('Child#pick'),
                             find_unit: ->(name, _type) { units[name] })
    end

    # What Child.new.pick returns with the conditions set to +flags+.
    def called(child, **flags)
      namespace = Module.new
      flags.each { |name, value| namespace.const_set(name, value) }
      namespace.module_eval(parent)
      namespace.module_eval(child)
      namespace.const_get(:Child).new.pick
    end

    it 'names the parent as the fallback of two independent conditions' do
      child = "class Child < Parent\n  if A\n    def pick = :a\n  end\n  if B\n    def pick = :b\n  end\nend\n"
      expect(called(child, A: false, B: false)).to eq(:parent)

      data = child_answer(child)

      expect(data['candidates'].map { |candidate| candidate.dig('member', 'line') }).to eq([3, 6])
      expect(data).not_to have_key('other_definitions')
      expect(data['caveats']).to eq(['Where Ruby runs none of the definitions above, it calls the next ' \
                                     'definition of pick: line 2 of the published source of Parent.'])
    end

    it 'names the parent as the fallback of a lone conditional definition' do
      child = "class Child < Parent\n  def pick = :a if A\nend\n"
      expect(called(child, A: false)).to eq(:parent)

      data = child_answer(child)

      expect(data['member']).to include('line' => 2)
      expect(data).not_to have_key('other_definitions')
      expect(data['caveats'].last).to eq('Where Ruby runs none of the definitions above, it calls the next ' \
                                         'definition of pick: line 2 of the published source of Parent.')
    end

    it 'keeps the parent overridden by an if and its else' do
      child = "class Child < Parent\n  if A\n    def pick = :a\n  else\n    def pick = :b\n  end\nend\n"
      expect([called(child, A: true), called(child, A: false)]).to eq(%i[a b])

      data = child_answer(child)

      expect(data['candidates'].map { |candidate| candidate.dig('member', 'line') }).to eq([3, 5])
      expect(data['other_definitions'].map { |entry| entry.values_at('unit', 'line') }).to eq([['Parent', 2]])
      expect(data).not_to have_key('caveats')
    end

    # Each body defines pick under A and B; the parent is overridden only
    # where Ruby calls it on no combination of the two.
    {
      'if, elsif and else' => ['if A then def pick = :a elsif B then def pick = :b else def pick = :c end', true],
      'if and elsif' => ['if A then def pick = :a elsif B then def pick = :b end', false],
      'unless and else' => ['unless A then def pick = :a else def pick = :b end', true],
      'case with an else' => ['case A when true then def pick = :a else def pick = :b end', true],
      'case without an else' => ['case A when true then def pick = :a when nil then def pick = :b end', false],
      'an if and its else, nested in a branch' =>
        ["if A\n    if B then def pick = :a else def pick = :b end\n  else def pick = :c end", true],
      'a block' => ['[].each { def pick = :a }; if A then def pick = :b end', false]
    }.each do |form, (body, covered)|
      it "#{covered ? 'overrides' : 'falls back to'} the parent for #{form}, as Ruby does" do
        child = "class Child < Parent\n  #{body}\nend\n"
        reached = [true, false].product([true, false]).map { |a, b| called(child, A: a, B: b) }
        expect(reached.include?(:parent)).to eq(!covered)

        data = child_answer(child)

        expect(data.key?('other_definitions')).to eq(covered)
      end
    end

    it 'lists no earlier plain definition that an if and its else both replace' do
      source = <<~RUBY
        class Alternative
          def pick = :plain
          if FLAG
            def pick = :first
          else
            def pick = :second
          end
        end
      RUBY
      expect([installed_line(source, true), installed_line(source, false)]).to eq([4, 6])

      data = answer(unit_for(source))

      expect(candidate_lines(data)).to eq([4, 6])
      expect(data['other_definitions'].map { |entry| entry['line'] }).to eq([2])
    end

    it 'lists no earlier plain definition of an inlined concern that an if and its else both replace' do
      concern = <<~RUBY
        module Choosing
          def pick = :plain
          if FLAG
            def pick = :first
          else
            def pick = :second
          end
        end
      RUBY
      namespace = Module.new
      namespace.const_set(:FLAG, false)
      namespace.module_eval(concern)
      expect(Class.new.include(namespace::Choosing).new.pick).to eq(:second)

      data = answer(unit_for(includer_of(concern), identity_lines: 2))

      expect(data['candidates'].map { |candidate| candidate['member'].values_at('file_unit', 'file_line') })
        .to eq([['Choosing', 4], ['Choosing', 6]])
      expect(data['other_definitions'].map { |entry| entry['file_line'] }).to eq([2])
    end

    it 'names the plain definition past a call that may define the name, and lists neither as overridden' do
      source = <<~RUBY
        class Alternative
          def self.maybe_define(name) = name
          def pick = :plain
          maybe_define :pick
          def pick = :conditional if FLAG
        end
      RUBY
      expect([installed_line(source, true), installed_line(source, false)]).to eq([5, 3])

      data = answer(unit_for(source))

      expect(data['member']).to include('line' => 5)
      expect(data).not_to have_key('other_definitions')
      expect(data['caveats'].last).to eq('Where Ruby runs none of the definitions above, it calls `maybe_define` ' \
                                         '(line 4 of the published source of Alternative), which may define ' \
                                         'pick, and otherwise the next definition of pick: line 3 of the ' \
                                         'published source of Alternative.')
    end
  end
end
