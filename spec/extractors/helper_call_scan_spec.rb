# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'woods/extractors/helper_call_scan'

RSpec.describe Woods::Extractors::HelperCallScan do
  describe '.method_calls' do
    let(:names) { Set.new(%w[pretty_date widget_badge title admin?]) }

    def calls(code, locals: [])
      described_class.method_calls(code, names, locals: locals)
    end

    it 'reports a receiverless call to a catalog name' do
      expect(calls('pretty_date(widget.shipped_at)')).to eq(bare: %w[pretty_date], explicit: [])
    end

    it 'reports each name once, sorted' do
      expect(calls("widget_badge(w)\npretty_date(a)\npretty_date(b)")[:bare]).to eq(%w[pretty_date widget_badge])
    end

    it 'ignores names outside the catalog' do
      expect(calls('link_to t(".label"), render("row")')).to eq(bare: [], explicit: [])
    end

    it 'reports a predicate name with its question mark' do
      expect(calls('if admin? then 1 end')[:bare]).to eq(%w[admin?])
    end

    it 'reports a call through the helpers proxy as explicit' do
      expect(calls('helpers.pretty_date(x)')).to eq(bare: [], explicit: %w[pretty_date])
    end

    it 'reports a helpers call chained on the next line' do
      expect(calls("helpers\n  .pretty_date(x)")[:explicit]).to eq(%w[pretty_date])
    end

    it 'ignores a method called on another receiver' do
      expect(calls('widget.title; widget&.pretty_date; Widget::title')).to eq(bare: [], explicit: [])
    end

    it 'does not treat a range as a receiver' do
      expect(calls('1..title')[:bare]).to eq(%w[title])
    end

    it 'ignores symbols, labels, and instance variables' do
      expect(calls('render :title, title: 1, as: :pretty_date, value: @title')).to eq(bare: [], explicit: [])
    end

    it 'reports a keyword argument value and both ternary branches' do
      expect(calls('tag(label: pretty_date, text: ok ? title : widget_badge)')[:bare])
        .to eq(%w[pretty_date title widget_badge])
    end

    it 'ignores string contents but reads interpolations' do
      expect(calls(%q(a = 'title' + "pretty_date #{widget_badge(w)} title"))[:bare]).to eq(%w[widget_badge])
    end

    it 'returns to string text after a nested interpolation closes' do
      expect(calls(<<~'RUBY')[:bare]).to eq(%w[title])
        "#{tag { "#{title}" }} pretty_date"
      RUBY
    end

    it 'ignores comments and word arrays' do
      expect(calls("# pretty_date\n%w[title pretty_date] + %i(title)")).to eq(bare: [], explicit: [])
    end

    it 'ignores a method definition' do
      expect(calls("def title\n  'x'\nend\ndef self.pretty_date; end")).to eq(bare: [], explicit: [])
    end

    it 'treats an assigned name as a local for the whole source' do
      expect(calls("title\ntitle = 'x'\ntitle ||= 'y'\nwidget_badge")[:bare]).to eq(%w[widget_badge])
    end

    it 'keeps a compared name as a call' do
      expect(calls("title == 'x' || pretty_date =~ /x/")[:bare]).to eq(%w[pretty_date title])
    end

    it 'treats block parameters as locals' do
      expect(calls("widgets.each do |title, i|\n title\nend\nrows.map { |pretty_date| pretty_date }")[:bare]).to eq([])
    end

    it 'treats local_assigns and defined? probes as locals' do
      expect(calls("local_assigns[:title]\nlocal_assigns.fetch(:pretty_date, 1)\ndefined?(widget_badge)\n" \
                   'title + pretty_date + widget_badge')[:bare]).to eq([])
    end

    it 'excludes locals the caller already knows' do
      expect(calls('title + pretty_date', locals: %w[title])[:bare]).to eq(%w[pretty_date])
    end

    it 'stops at an unterminated quote instead of reading its text as code' do
      expect(calls("x = 'open\npretty_date")[:bare]).to eq([])
    end

    it 'skips a heredoc body, apostrophes and all' do
      code = "sql = <<~SQL\n  select title from widgets where it's pretty_date\nSQL\nwidget_badge(w)"
      expect(calls(code)[:bare]).to eq(%w[widget_badge])
    end

    it 'reads the rest of the line that opens a heredoc' do
      expect(calls("tag(<<~TEXT, pretty_date) # note\n  title\nTEXT\n")[:bare]).to eq(%w[pretty_date])
    end

    it 'skips each body when one line opens two heredocs' do
      expect(calls("pair(<<-A, <<-'B')\n  title\n  A\n  pretty_date\n  B\nwidget_badge")[:bare])
        .to eq(%w[widget_badge])
    end

    it 'does not read a shift operator as a heredoc' do
      expect(calls("list << title\nwidget_badge")[:bare]).to eq(%w[title widget_badge])
    end

    it 'scans source that is not valid UTF-8' do
      expect(calls("pretty_date \xFF title".dup.force_encoding(Encoding::UTF_8))[:bare]).to eq(%w[pretty_date title])
    end
  end
end
