# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'codebase_index/extractors/controller_extractor'

RSpec.describe CodebaseIndex::Extractors::ControllerExtractor do
  # ── Test doubles ──────────────────────────────────────────────────────
  #
  # Mock ActionFilter: an object with an @actions ivar (Set of strings),
  # matching how Rails stores :only/:except since 4.2.
  #
  # Mock Callback: an object with @if/@unless arrays, .kind, and .filter,
  # matching ActiveSupport::Callbacks::Callback's interface.

  def build_action_filter(actions)
    obj = Object.new
    obj.instance_variable_set(:@actions, Set.new(actions.map(&:to_s)))
    obj
  end

  def build_callback(kind:, filter:, if_conditions: [], unless_conditions: [])
    obj = Object.new
    obj.instance_variable_set(:@if, if_conditions)
    obj.instance_variable_set(:@unless, unless_conditions)
    obj.define_singleton_method(:kind) { kind }
    obj.define_singleton_method(:filter) { filter }
    obj
  end

  # We test the private helpers by sending them through a fresh instance.
  # The extractor needs Rails.application.routes to initialize, so we stub that.
  let(:extractor) do
    routes_double = double('Routes', routes: [])
    app_double = double('Application', routes: routes_double)
    stub_const('Rails', double('Rails', application: app_double))
    described_class.new
  end

  # ── extract_callback_conditions ──────────────────────────────────────

  describe '#extract_callback_conditions' do
    it 'extracts :only actions from @if ActionFilter' do
      filter = build_action_filter(%w[create update])
      callback = build_callback(kind: :before, filter: :authenticate!, if_conditions: [filter])

      only, except, if_labels, unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to match_array(%w[create update])
      expect(except).to be_empty
      expect(if_labels).to be_empty
      expect(unless_labels).to be_empty
    end

    it 'extracts :except actions from @unless ActionFilter' do
      filter = build_action_filter(%w[index show])
      callback = build_callback(kind: :before, filter: :require_login, unless_conditions: [filter])

      only, except, if_labels, unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to be_empty
      expect(except).to match_array(%w[index show])
      expect(if_labels).to be_empty
      expect(unless_labels).to be_empty
    end

    it 'handles mixed ActionFilter and proc conditions' do
      action_filter = build_action_filter(%w[destroy])
      proc_condition = proc { true }
      callback = build_callback(
        kind: :before, filter: :verify_admin,
        if_conditions: [action_filter, proc_condition]
      )

      only, _, if_labels, _unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to eq(%w[destroy])
      expect(if_labels).to eq(['Proc'])
    end

    it 'handles callbacks with no conditions' do
      callback = build_callback(kind: :before, filter: :set_locale)

      only, except, if_labels, unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(only).to be_empty
      expect(except).to be_empty
      expect(if_labels).to be_empty
      expect(unless_labels).to be_empty
    end

    it 'handles symbol conditions' do
      callback = build_callback(kind: :before, filter: :check_role, if_conditions: [:admin?])

      _only, _except, if_labels, _unless_labels = extractor.send(:extract_callback_conditions, callback)

      expect(if_labels).to eq([':admin?'])
    end
  end

  # ── callback_applies_to_action? ──────────────────────────────────────

  describe '#callback_applies_to_action?' do
    it 'returns true when action is in :only list' do
      filter = build_action_filter(%w[create update])
      callback = build_callback(kind: :before, filter: :auth, if_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'create')).to be true
    end

    it 'returns false when action is NOT in :only list' do
      filter = build_action_filter(%w[create update])
      callback = build_callback(kind: :before, filter: :auth, if_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'index')).to be false
    end

    it 'returns false when action is in :except list' do
      filter = build_action_filter(%w[index show])
      callback = build_callback(kind: :before, filter: :auth, unless_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'index')).to be false
    end

    it 'returns true when action is NOT in :except list' do
      filter = build_action_filter(%w[index show])
      callback = build_callback(kind: :before, filter: :auth, unless_conditions: [filter])

      expect(extractor.send(:callback_applies_to_action?, callback, 'create')).to be true
    end

    it 'returns true when no conditions present (applies to all)' do
      callback = build_callback(kind: :before, filter: :set_locale)

      expect(extractor.send(:callback_applies_to_action?, callback, 'anything')).to be true
    end

    it 'skips non-ActionFilter conditions (assumes true)' do
      proc_condition = proc { true }
      callback = build_callback(kind: :before, filter: :check, if_conditions: [proc_condition])

      expect(extractor.send(:callback_applies_to_action?, callback, 'index')).to be true
    end
  end

  # ── extract_action_filter_actions ────────────────────────────────────

  describe '#extract_action_filter_actions' do
    it 'returns action names from an ActionFilter' do
      filter = build_action_filter(%w[show edit])

      result = extractor.send(:extract_action_filter_actions, filter)

      expect(result).to match_array(%w[show edit])
    end

    it 'returns nil for a plain proc' do
      result = extractor.send(:extract_action_filter_actions, proc { true })
      expect(result).to be_nil
    end

    it 'returns nil for a symbol' do
      result = extractor.send(:extract_action_filter_actions, :admin?)
      expect(result).to be_nil
    end

    it 'returns nil if @actions is not a Set' do
      obj = Object.new
      obj.instance_variable_set(:@actions, 'not a set')

      result = extractor.send(:extract_action_filter_actions, obj)
      expect(result).to be_nil
    end
  end

  # ── condition_label ──────────────────────────────────────────────────

  describe '#condition_label' do
    it 'labels symbols with colon prefix' do
      expect(extractor.send(:condition_label, :admin?)).to eq(':admin?')
    end

    it "labels procs as 'Proc'" do
      expect(extractor.send(:condition_label, proc { true })).to eq('Proc')
    end

    it 'labels strings as themselves' do
      expect(extractor.send(:condition_label, 'user_signed_in?')).to eq('user_signed_in?')
    end
  end

  # ── nesting_delta ──────────────────────────────────────────────────

  describe '#nesting_delta' do
    it 'counts def as +1' do
      expect(extractor.send(:nesting_delta, '  def show')).to eq(1)
    end

    it 'counts end as -1' do
      expect(extractor.send(:nesting_delta, '  end')).to eq(-1)
    end

    it 'counts begin as +1' do
      expect(extractor.send(:nesting_delta, '  begin')).to eq(1)
    end

    it 'counts case as +1' do
      expect(extractor.send(:nesting_delta, '  case value')).to eq(1)
    end

    it 'counts do as +1' do
      expect(extractor.send(:nesting_delta, '  items.each do |item|')).to eq(1)
    end

    it 'counts if at statement start as +1' do
      expect(extractor.send(:nesting_delta, '  if condition')).to eq(1)
    end

    it 'counts unless at statement start as +1' do
      expect(extractor.send(:nesting_delta, '  unless condition')).to eq(1)
    end

    it 'counts if after = as +1' do
      expect(extractor.send(:nesting_delta, '  x = if condition')).to eq(1)
    end

    it 'does not count postfix if' do
      expect(extractor.send(:nesting_delta, '  return if condition')).to eq(0)
    end

    it 'does not count postfix unless' do
      expect(extractor.send(:nesting_delta, '  raise unless valid')).to eq(0)
    end

    it 'does not double-count while + do' do
      expect(extractor.send(:nesting_delta, '  while true do')).to eq(1)
    end

    it 'does not double-count for + do' do
      expect(extractor.send(:nesting_delta, '  for x in items do')).to eq(1)
    end

    it 'handles one-liner def...end as 0' do
      expect(extractor.send(:nesting_delta, '  def foo; end')).to eq(0)
    end

    it 'ignores keywords in double-quoted strings' do
      expect(extractor.send(:nesting_delta, '  puts "end of the world"')).to eq(0)
    end

    it 'ignores keywords in single-quoted strings' do
      expect(extractor.send(:nesting_delta, "  puts 'if you end this'")).to eq(0)
    end

    it 'ignores keywords in comments' do
      expect(extractor.send(:nesting_delta, '  x = 1 # if this end happens')).to eq(0)
    end

    it 'does not change depth for rescue' do
      expect(extractor.send(:nesting_delta, '  rescue StandardError => e')).to eq(0)
    end

    it 'does not change depth for ensure' do
      expect(extractor.send(:nesting_delta, '  ensure')).to eq(0)
    end

    it 'does not change depth for elsif' do
      expect(extractor.send(:nesting_delta, '  elsif other_condition')).to eq(0)
    end

    it 'does not change depth for else' do
      expect(extractor.send(:nesting_delta, '  else')).to eq(0)
    end

    it 'returns 0 for blank lines' do
      expect(extractor.send(:nesting_delta, '')).to eq(0)
      expect(extractor.send(:nesting_delta, '   ')).to eq(0)
    end

    it 'returns 0 for comment-only lines' do
      expect(extractor.send(:nesting_delta, '  # just a comment')).to eq(0)
    end
  end

  # ── detect_heredoc_start ──────────────────────────────────────────

  describe '#detect_heredoc_start' do
    it 'detects <<~WORD heredocs' do
      expect(extractor.send(:detect_heredoc_start, '  text = <<~SQL')).to eq('SQL')
    end

    it 'detects <<-WORD heredocs' do
      expect(extractor.send(:detect_heredoc_start, '  text = <<-EOF')).to eq('EOF')
    end

    it 'detects quoted heredoc delimiters' do
      expect(extractor.send(:detect_heredoc_start, "  text = <<~'SQL'")).to eq('SQL')
    end

    it 'returns nil for non-heredoc lines' do
      expect(extractor.send(:detect_heredoc_start, '  x = 1 + 2')).to be_nil
    end

    it 'returns nil for heredoc markers inside strings' do
      expect(extractor.send(:detect_heredoc_start, '  puts "<<~SQL"')).to be_nil
    end
  end

  # ── extract_filter_chain (integration) ───────────────────────────────

  describe '#extract_filter_chain' do
    it 'builds filter chain from mocked controller callbacks' do
      only_filter = build_action_filter(%w[create update])
      except_filter = build_action_filter(%w[index])

      callbacks = [
        build_callback(kind: :before, filter: :authenticate_user!, if_conditions: [only_filter]),
        build_callback(kind: :before, filter: :set_locale),
        build_callback(kind: :after, filter: :track_action, unless_conditions: [except_filter])
      ]

      controller = double('Controller', _process_action_callbacks: callbacks)

      chain = extractor.send(:extract_filter_chain, controller)

      expect(chain.size).to eq(3)

      expect(chain[0][:kind]).to eq(:before)
      expect(chain[0][:filter]).to eq(:authenticate_user!)
      expect(chain[0][:only]).to match_array(%w[create update])
      expect(chain[0]).not_to have_key(:except)

      expect(chain[1][:kind]).to eq(:before)
      expect(chain[1][:filter]).to eq(:set_locale)
      expect(chain[1]).not_to have_key(:only)
      expect(chain[1]).not_to have_key(:except)

      expect(chain[2][:kind]).to eq(:after)
      expect(chain[2][:filter]).to eq(:track_action)
      expect(chain[2][:except]).to eq(%w[index])
    end
  end
end
