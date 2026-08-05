# frozen_string_literal: true

require 'spec_helper'
require 'woods/chunking/semantic_chunker'

RSpec.describe Woods::Chunking::LineDepthTracking do
  subject(:tracker) { Class.new { include Woods::Chunking::LineDepthTracking }.new }

  describe '#endless_def?' do
    it 'detects a bare endless def' do
      expect(tracker.send(:endless_def?, 'def show = head :ok')).to be(true)
    end

    it 'detects an endless def with parameters' do
      expect(tracker.send(:endless_def?, 'def double(number) = number * 2')).to be(true)
    end

    it 'detects an endless singleton def' do
      expect(tracker.send(:endless_def?, 'def self.build = new')).to be(true)
    end

    it 'detects an endless predicate def' do
      expect(tracker.send(:endless_def?, '  def valid? = errors.empty?')).to be(true)
    end

    it 'detects an endless operator def' do
      expect(tracker.send(:endless_def?, 'def ==(other) = amount == other.amount')).to be(true)
    end

    it 'treats def ==(other) with a body as a normal method definition' do
      expect(tracker.send(:endless_def?, 'def ==(other)')).to be(false)
    end

    it 'treats a setter def x=(v) as a normal method definition' do
      expect(tracker.send(:endless_def?, 'def x=(value)')).to be(false)
    end

    it 'treats a space-form setter def as a normal method definition' do
      expect(tracker.send(:endless_def?, 'def x= value')).to be(false)
    end

    it 'treats a bare def as not endless' do
      expect(tracker.send(:endless_def?, 'def create')).to be(false)
    end

    it 'treats a def with parameters and no marker as not endless' do
      expect(tracker.send(:endless_def?, 'def create(params)')).to be(false)
    end
  end

  describe '#block_opener?' do
    it 'counts a do block' do
      expect(tracker.send(:block_opener?, '  items.each do |item|')).to be(true)
    end

    it 'counts a do block without args' do
      expect(tracker.send(:block_opener?, '  transaction do')).to be(true)
    end

    it 'counts a do block with a trailing comment' do
      expect(tracker.send(:block_opener?, '  items.each do |item| # loop')).to be(true)
    end

    it 'counts a leading if' do
      expect(tracker.send(:block_opener?, '  if ready?')).to be(true)
    end

    it 'counts a leading unless' do
      expect(tracker.send(:block_opener?, 'unless done?')).to be(true)
    end

    it 'counts a leading case' do
      expect(tracker.send(:block_opener?, 'case status')).to be(true)
    end

    it 'counts a leading begin' do
      expect(tracker.send(:block_opener?, 'begin')).to be(true)
    end

    it 'counts a leading while' do
      expect(tracker.send(:block_opener?, 'while queue.any?')).to be(true)
    end

    it 'counts a leading until' do
      expect(tracker.send(:block_opener?, 'until finished?')).to be(true)
    end

    it 'counts a nested def' do
      expect(tracker.send(:block_opener?, '  def helper')).to be(true)
    end

    it 'counts an assignment-position if' do
      expect(tracker.send(:block_opener?, 'status = if urgent?')).to be(true)
    end

    it 'counts a memoized begin' do
      expect(tracker.send(:block_opener?, '@config ||= begin')).to be(true)
    end

    it 'ignores a trailing if modifier' do
      expect(tracker.send(:block_opener?, 'return if cancelled?')).to be(false)
    end

    it 'ignores a trailing unless modifier' do
      expect(tracker.send(:block_opener?, 'raise Error unless valid?')).to be(false)
    end

    it 'ignores a trailing while modifier' do
      expect(tracker.send(:block_opener?, 'retry_count += 1 while busy?')).to be(false)
    end

    it 'ignores a trailing until modifier' do
      expect(tracker.send(:block_opener?, 'sleep 1 until ready?')).to be(false)
    end

    it 'ignores a case/in pattern-matching clause' do
      expect(tracker.send(:block_opener?, "in { type: 'a' }")).to be(false)
    end

    it 'ignores a ternary' do
      expect(tracker.send(:block_opener?, 'x = urgent? ? escalate : queue')).to be(false)
    end

    it 'ignores a self-balancing one-line if...end' do
      expect(tracker.send(:block_opener?, 'if x then y end')).to be(false)
    end

    it 'ignores keywords in comment lines' do
      expect(tracker.send(:block_opener?, '  # def foo — do it later')).to be(false)
    end

    it 'ignores an endless def' do
      expect(tracker.send(:block_opener?, 'def show = head :ok')).to be(false)
    end

    it 'ignores keyword-prefixed identifiers' do
      expect(tracker.send(:block_opener?, 'x = format(template)')).to be(false)
    end
  end

  describe '#block_terminator?' do
    it 'matches a bare end' do
      expect(tracker.send(:block_terminator?, '  end')).to be(true)
    end

    it 'matches a chained end' do
      expect(tracker.send(:block_terminator?, '  end.compact')).to be(true)
    end

    it 'matches a modifier end (begin...end while)' do
      expect(tracker.send(:block_terminator?, 'end while retry?')).to be(true)
    end

    it 'does not match an end: hash key' do
      expect(tracker.send(:block_terminator?, 'end: 1,')).to be(false)
    end

    it 'does not match identifiers ending in end' do
      expect(tracker.send(:block_terminator?, 'notify_friend')).to be(false)
    end

    it 'does not match end inside a comment' do
      expect(tracker.send(:block_terminator?, '# end of section')).to be(false)
    end
  end

  describe '#operator_def_name' do
    it 'extracts an operator name' do
      expect(tracker.send(:operator_def_name, '  def ==(other)')).to eq('==')
    end

    it 'extracts the spaceship operator' do
      expect(tracker.send(:operator_def_name, 'def <=>(other)')).to eq('<=>')
    end

    it 'returns nil for plain method names' do
      expect(tracker.send(:operator_def_name, 'def create')).to be_nil
    end
  end
end
