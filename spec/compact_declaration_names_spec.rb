# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'set'
require 'active_support/concern'
require 'woods/extracted_unit'
require 'woods/extractors/source_nesting'
require 'woods/extractors/mixin_calls'
require 'woods/method_table'
require 'woods/ruby_analyzer'
require 'woods/mcp/lookup_member'

# Every static reader names a module or class declaration as Ruby does once
# the same source is evaluated. A qualified declaration's first constant is
# looked up lexically: the enclosing bodies' own constants innermost first,
# then the top level; `::X` is absolute. Each fixture's names are checked
# against the modules Ruby opens while it evaluates the source.
RSpec.describe 'Compact declaration names' do
  # source: the file the readers see, ending in the declaration that holds
  #   `def touch`. other: another file Ruby evaluated first. names: the
  #   qualified name of each declaration in the source, in order.
  fixtures = {
    'a prefix naming the enclosing module' => {
      source: "module Billing\n  class Billing::Invoice\n    def touch; end\n  end\nend\n",
      names: %w[Billing Billing::Invoice]
    },
    'a compact module, then a plain class inside it' => {
      source: "module Billing\n  module Billing::Ledger\n    class Entry\n      def touch; end\n    end\n  end\nend\n",
      names: %w[Billing Billing::Ledger Billing::Ledger::Entry]
    },
    'a prefix naming an outer module, not the innermost' => {
      source: "module Billing\n  module Reports\n    class Billing::Summary\n      def touch; end\n    end\n  end\n" \
              "end\n",
      names: %w[Billing Billing::Reports Billing::Summary]
    },
    'a deep prefix whose middle module another file declares' => {
      other: "module Billing\n  module Ledger; end\nend\n",
      source: "module Billing\n  class Billing::Ledger::Entry\n    def touch; end\n  end\nend\n",
      names: %w[Billing Billing::Ledger::Entry]
    },
    'a top-level compact declaration' => {
      other: "module Billing; end\n",
      source: "class Billing::Invoice\n  def touch; end\nend\n",
      names: %w[Billing::Invoice]
    },
    'a prefix another file nests inside the enclosing module' => {
      other: "module Billing\n  class Invoice; end\nend\n",
      source: "module Billing\n  class Invoice::Line\n    def touch; end\n  end\nend\n",
      names: %w[Billing Billing::Invoice::Line]
    },
    'a prefix the source nests inside the enclosing module first' => {
      source: "module Billing\n  module Billing; end\n  class Billing::Invoice\n    def touch; end\n  end\nend\n",
      names: %w[Billing Billing::Billing Billing::Billing::Invoice]
    },
    'a prefix another file nests nearer than a top-level module the source declares' => {
      other: "module Billing\n  class Invoice; end\nend\n",
      source: "class Invoice; end\nmodule Billing\n  class Invoice::Line\n    def touch; end\n  end\nend\n",
      names: %w[Invoice Billing Billing::Invoice::Line]
    },
    'a prefix another file nests nearer than a sibling module the source declares' => {
      other: "module Billing\n  module Reports\n    class Invoice; end\n  end\nend\n",
      source: <<~RUBY,
        module Billing
          class Invoice; end
          module Reports
            class Invoice::Line
              def touch; end
            end
          end
        end
      RUBY
      names: %w[Billing Billing::Invoice Billing::Reports Billing::Reports::Invoice::Line]
    },
    'a prefix whose nested namespace the source declares only afterwards' => {
      source: "module Billing\n  class Billing::Invoice; end\n  module Billing\n    def touch; end\n  end\nend\n",
      names: %w[Billing Billing::Invoice Billing::Billing]
    }
  }.freeze

  # Opens the absolute declaration's target at the top level, where `::`
  # looks, under a name no other spec uses.
  absolute = {
    root: 'CompactDeclarationRoot',
    source: <<~RUBY,
      module Reports
        class ::CompactDeclarationRoot::Refund
          class Line
            def touch; end
          end
        end
      end
    RUBY
    names: %w[Reports CompactDeclarationRoot::Refund CompactDeclarationRoot::Refund::Line]
  }.freeze

  # The qualified names of the modules and classes Ruby opens while it
  # evaluates +source+ inside a fresh namespace, in order.
  def runtime_names(source, other: nil)
    namespace = Module.new
    namespace.module_eval(other) if other
    opened = []
    trace = TracePoint.new(:class) { |event| opened << event.self.name.sub(/\A#<Module:0x\h+>::/, '') }
    trace.enable { namespace.module_eval(source) }
    opened
  end

  def scanner
    Class.new { include Woods::Extractors::SourceNesting }.new
  end

  def static_names(source)
    analyzed = Woods::RubyAnalyzer.analyze(sources: { '/app/lib/sample.rb' => source })
    {
      lexical_scopes: Woods::Extractors::SourceNesting.lexical_scopes(source).map(&:last),
      declarations: [].tap do |names|
        scanner.send(:each_declaration, source) { |_kind, _name, qualified| names << qualified }
      end,
      ruby_analyzer: analyzed.select { |unit| %i[ruby_class ruby_module].include?(unit.type) }.map(&:identifier)
    }
  end

  def leaf_readers(source, leaf)
    analyzed = Woods::RubyAnalyzer.analyze(sources: { '/app/lib/sample.rb' => source })
    {
      method_table_owners: Woods::MethodTable.call(source).map { |entry| entry['owner'] },
      method_analyzer: analyzed.select { |unit| unit.type == :ruby_method }.map(&:identifier),
      written_name: Woods::MCP::LookupMember::Resolution::WrittenName.call(source, leaf),
      mixin_calls_declares: Woods::Extractors::MixinCalls.visit(source, [], false).declares?(leaf)
    }
  end

  fixtures.each do |label, fixture|
    it "names #{label} as Ruby does" do
      names = fixture[:names]
      leaf = names.last
      expect(runtime_names(fixture[:source], other: fixture[:other])).to eq(names)

      expect(static_names(fixture[:source])).to eq(lexical_scopes: names, declarations: names, ruby_analyzer: names)
      expect(leaf_readers(fixture[:source], leaf)).to eq(
        method_table_owners: [leaf], method_analyzer: ["#{leaf}#touch"], written_name: leaf, mixin_calls_declares: true
      )
    end
  end

  it 'names an absolute declaration and its body as Ruby does' do
    Object.const_set(absolute[:root], Module.new)
    expect(runtime_names(absolute[:source])).to eq(absolute[:names])
    leaf = absolute[:names].last

    expect(static_names(absolute[:source])).to eq(
      lexical_scopes: absolute[:names], declarations: absolute[:names], ruby_analyzer: absolute[:names]
    )
    expect(leaf_readers(absolute[:source], leaf)).to eq(
      method_table_owners: [leaf], method_analyzer: ["#{leaf}#touch"], written_name: leaf, mixin_calls_declares: true
    )
  ensure
    Object.send(:remove_const, absolute[:root]) if Object.const_defined?(absolute[:root], false)
  end

  it 'names the first class of a source written in the compact form' do
    source = "module Billing\n  class Billing::Invoice\n  end\nend\n"
    expect(scanner.qualified_first_class_name(source)).to eq('Billing::Invoice')
  end

  it 'matches the governed name of a compact declaration under a managed path' do
    source = "module Billing\n  class Billing::InvoiceService\n  end\nend\n"
    expect(scanner.governed_class_name('/rails/app/services/billing/invoice_service.rb', source))
      .to eq('Billing::InvoiceService')
  end

  it 'names a concern written in the compact form inside its namespace module' do
    source = "module Billing\n  module Billing::Trackable\n    def track; end\n  end\nend\n"
    expect(runtime_names(source)).to eq(%w[Billing Billing::Trackable])
    expect(scanner.qualified_outer_module_name(source)).to eq('Billing::Trackable')
  end

  it 'reads the class_methods block of a concern written in the compact form' do
    source = <<~RUBY
      module Billing
        module Billing::Trackable
          extend ActiveSupport::Concern
          class_methods do
            def track; end
          end
        end
      end
    RUBY
    namespace = Module.new
    namespace.module_eval(source)
    expect(Class.new.include(namespace::Billing::Trackable)).to respond_to(:track)

    expect(Woods::MCP::LookupMember::ConcernClassMethods.own_lines(source, 'Billing::Trackable')).to eq(Set[5])
  end

  it 'reads the mixin calls in the body of a class written in the compact form' do
    source = "module Billing\n  class Billing::Invoice\n    include Comparable\n  end\nend\n"
    namespace = Module.new
    namespace.module_eval(source)
    expect(namespace::Billing::Invoice.include?(Comparable)).to be(true)

    expect(Woods::MCP::LookupMember::Resolution::Mixins.calls(source, 'Billing::Invoice', :include))
      .to eq([['Comparable', %w[Billing::Invoice Billing]]])
  end

  it 'answers a member lookup on a unit whose source writes the compact form' do
    source = "module Billing\n  class Billing::Invoice\n    def total; end\n  end\nend\n"
    unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Billing::Invoice',
                                    file_path: 'app/models/billing/invoice.rb')
    unit.source_code = source
    Woods::MethodTable.record(unit)
    published = JSON.parse(JSON.generate(unit.to_h))
    reference = Woods::MCP::LookupMember.parse('Billing::Invoice#total')

    expect(Woods::MCP::LookupMember.answer(published, reference)&.dig('member', 'owner')).to eq('Billing::Invoice')
  end

  # Only the runtime can tell these apart from the forms above, so the
  # difference from Ruby is recorded here. The second source is the same as
  # the first fixture's; on a Zeitwerk-managed path `billing/invoice.rb` must
  # define Billing::Invoice, which is the name the readers give it.
  describe 'where only the runtime knows the prefix' do
    it 'keeps the nested name for a prefix a superclass supplies' do
      other = "class Base\n  module Helper; end\nend\n"
      source = "class Report < Base\n  class Helper::Row\n    def touch; end\n  end\nend\n"

      expect(runtime_names(source, other: other)).to eq(%w[Report Base::Helper::Row])
      expect(static_names(source)[:declarations]).to eq(%w[Report Report::Helper::Row])
    end

    it 'reads the prefix as the enclosing module when only another file nests one of that name inside it' do
      other = "module Billing\n  module Billing; end\nend\n"
      source = "module Billing\n  class Billing::Invoice\n    def touch; end\n  end\nend\n"

      expect(runtime_names(source, other: other)).to eq(%w[Billing Billing::Billing::Invoice])
      expect(static_names(source)[:declarations]).to eq(%w[Billing Billing::Invoice])
    end
  end
end
