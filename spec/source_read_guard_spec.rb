# frozen_string_literal: true

require 'spec_helper'
require 'prism'

# Host source goes through Woods::SourceFile and Woods-written artifacts
# through Woods::AtomicFile. A bare File.read tags bytes with the process
# default external encoding. A Rails boot sets that from config.encoding
# (UTF-8 by default), but the stdio and HTTP servers, the watcher before
# boot, rake tasks without :environment and PublishedIndex readers never
# boot Rails: under LC_ALL=C they see US-ASCII and raise on the first
# multibyte byte. Pinning `encoding:` at a call site is not enough for host
# source either: it leaves invalid UTF-8 unscrubbed. File.binread is
# locale-independent by design and is not flagged.
module SourceReadGuard
  ROOT = File.expand_path('..', __dir__)
  SCANNED = %w[
    lib/woods/extractor.rb lib/woods/extractors/**/*.rb lib/woods/flow_*.rb lib/woods/flow_analysis/**/*.rb
    lib/woods/source_references/**/*.rb lib/woods/mcp/**/*.rb exe/* lib/woods/published_index.rb
    lib/woods/published_index/**/*.rb lib/woods/watch/**/*.rb lib/woods/checks/**/*.rb lib/tasks/**/*.rake
    lib/woods/tasks.rb lib/woods/rake_helpers.rb
  ].freeze
  RECEIVERS = %w[File IO].freeze
  READERS = %i[read readlines foreach].freeze
  # Pathname#read and friends go through File with the same default encoding.
  # A receiver built by `join` (Array#join returns a String, which has no
  # #read), Pathname.new or Kernel#Pathname is a Pathname.
  PATHNAME_READERS = %i[read readlines each_line].freeze

  # [relative path, enclosing method] => why the read stays. Every entry
  # must still match a read, so a stale entry fails too.
  ALLOWED = {
    ['lib/woods/extractors/lib_extractor.rb', 'build_file'] =>
      'pins UTF-8 and refuses invalid source outright (its own contract), never scrubs',
    ['lib/woods/mcp/tasks/store.rb', 'current_boot_identity'] =>
      'kernel boot id under /proc: ASCII by definition',
    ['lib/woods/mcp/tasks/store.rb', 'linux_process_identity'] =>
      'kernel boot id and process stat under /proc: ASCII by definition',
    ['lib/woods/extractors/config_file_extractor.rb', 'read_outline'] =>
      'reports invalid UTF-8 as parse_error metadata (its own contract), never scrubs',
    ['lib/woods/extractors/test_support_catalog.rb', 'analyze'] =>
      'refuses invalid UTF-8 with ArgumentError (documented contract), never scrubs',
    ['lib/woods/extractors/external_consumer_declarations.rb', 'load_file'] =>
      'a declaration file with invalid UTF-8 is a configuration error, not source to scrub'
  }.freeze

  # Collects receiver-qualified File/IO reads with their enclosing method.
  class Visitor < Prism::Visitor
    attr_reader :reads

    def initialize
      super
      @reads = []
      @methods = []
    end

    def visit_def_node(node)
      @methods.push(node.name.to_s)
      super
    ensure
      @methods.pop
    end

    def visit_call_node(node)
      @reads << { method: @methods.last, line: node.location.start_line, call: node.slice } if bare_read?(node)
      super
    end

    private

    def bare_read?(node)
      (READERS.include?(node.name) && RECEIVERS.include?(receiver_name(node.receiver))) ||
        (PATHNAME_READERS.include?(node.name) && pathname?(node.receiver))
    end

    def pathname?(receiver)
      return false unless receiver.is_a?(Prism::CallNode)
      return true if receiver.name == :join && receiver.receiver
      return true if receiver.name == :new && receiver_name(receiver.receiver) == 'Pathname'

      receiver.name == :Pathname && receiver.receiver.nil?
    end

    def receiver_name(receiver)
      case receiver
      when Prism::ConstantReadNode then receiver.name.to_s
      when Prism::ConstantPathNode then receiver.parent.nil? ? receiver.name.to_s : nil
      end
    end
  end

  module_function

  # @param source [String] Ruby source
  # @return [Array<Hash>] each bare read's enclosing method, line and call text
  def reads_in(source)
    visitor = Visitor.new
    Prism.parse(source).value.accept(visitor)
    visitor.reads
  end

  # @return [Array<Hash>] every bare read in the scanned files, with its path
  def scanned_reads
    SCANNED.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }.sort.flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      reads_in(File.read(path, encoding: Encoding::UTF_8)).map { |read| read.merge(path: relative) }
    end
  end
end

RSpec.describe 'host source and index reads outside a Rails boot' do
  it 'go through SourceFile or AtomicFile, apart from the allowlisted reads' do
    offenses = SourceReadGuard.scanned_reads.reject do |read|
      SourceReadGuard::ALLOWED.key?([read[:path], read[:method]])
    end

    expect(offenses.map { |read| "#{read[:path]}:#{read[:line]} #{read[:call]}" }).to eq([])
  end

  it 'keeps no allowlist entry that no longer matches a read' do
    matched = SourceReadGuard.scanned_reads.map { |read| [read[:path], read[:method]] }

    expect(SourceReadGuard::ALLOWED.keys - matched).to eq([])
  end

  describe 'the scanner' do
    it 'flags File and IO reads, pinned encoding or not, with their enclosing method' do
      source = <<~RUBY
        class Widget
          def load(path)
            File.read(path)
            ::File.readlines(path, encoding: Encoding::UTF_8)
            IO.read(path)
            File.foreach(path) { |line| line }
            File.binread(path)
          end
        end
      RUBY

      expect(SourceReadGuard.reads_in(source).map { |read| [read[:method], read[:line]] })
        .to eq([['load', 3], ['load', 4], ['load', 5], ['load', 6]])
    end

    it 'flags Pathname reads built from a join, Pathname.new or Pathname()' do
      source = <<~RUBY
        def load(path)
          Rails.root.join(path).read
          root.join('config', path).readlines
          Pathname.new(path).read
          ::Pathname.new(path).each_line { |line| line }
          Pathname(path).read
          Rails.root.join(path).binread
        end
      RUBY

      expect(SourceReadGuard.reads_in(source).map { |read| [read[:method], read[:line]] })
        .to eq([['load', 2], ['load', 3], ['load', 4], ['load', 5], ['load', 6]])
    end

    it 'ignores the sanctioned readers, other receivers, comments and strings' do
      source = <<~RUBY
        # File.read(path) in a comment
        Woods::AtomicFile.read(path)
        SourceFile.read(path)
        Widget::File.read(path)
        file.read
        %w[a b].join(',').length
        Widget.new(path).read
        "File.read(path)"
      RUBY

      expect(SourceReadGuard.reads_in(source)).to eq([])
    end
  end
end
