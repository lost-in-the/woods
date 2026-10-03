# frozen_string_literal: true

require 'spec_helper'
require 'prism'

# Host source must be read through Woods::SourceFile. A bare File.read tags it
# with the process default external encoding, which is US-ASCII under a POSIX
# locale, and the extractor's per-file rescue then drops the unit silently.
# Pinning `encoding:` at the call site is not enough either: it leaves invalid
# UTF-8 unscrubbed, so one file can still raise where every other is scrubbed.
module SourceReadGuard
  ROOT = File.expand_path('../..', __dir__)
  SCANNED = ['lib/woods/extractor.rb', 'lib/woods/extractors/**/*.rb'].freeze
  RECEIVERS = %w[File IO].freeze
  READERS = %i[read readlines foreach binread].freeze

  # [relative path, enclosing method] => why the read is not host source
  # through SourceFile. Every entry must still match a read, so a stale entry
  # fails too.
  ALLOWED = {
    ['lib/woods/extractors/lib_extractor.rb', 'build_file'] =>
      'pins UTF-8 and refuses invalid source outright (its own contract), never scrubs'
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
      READERS.include?(node.name) && RECEIVERS.include?(receiver_name(node.receiver))
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

RSpec.describe 'host source reads in the extractors' do
  it 'go through SourceFile, apart from the allowlisted non-scrubbing reads' do
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
          end
        end
      RUBY

      expect(SourceReadGuard.reads_in(source).map { |read| [read[:method], read[:line]] })
        .to eq([['load', 3], ['load', 4], ['load', 5], ['load', 6]])
    end

    it 'ignores the sanctioned readers, other receivers, comments and strings' do
      source = <<~RUBY
        # File.read(path) in a comment
        Woods::AtomicFile.read(path)
        SourceFile.read(path)
        Widget::File.read(path)
        file.read
        "File.read(path)"
      RUBY

      expect(SourceReadGuard.reads_in(source)).to eq([])
    end
  end
end
