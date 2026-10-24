# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/callback_sites'

RSpec.describe Woods::CallbackSites do
  def concern_block(name, code)
    indented = code.lines.map { |line| "  # #{line.rstrip}" }.join("\n")
    <<~CONCERN
      # ┌─────────────────────────────────────────────────────────────────────┐
      # │ Included from: #{name.ljust(54)}│
      # └─────────────────────────────────────────────────────────────────────┘
      #{indented}
      # ─────────────────────────── End #{name} ───────────────────────────
    CONCERN
  end

  def unit(source, callbacks)
    Woods::ExtractedUnit.new(type: :model, identifier: 'Post', file_path: 'app/models/post.rb').tap do |u|
      u.source_code = source
      u.metadata[:callbacks] = callbacks
    end
  end

  def callback(type, filter)
    { type: type, filter: filter, kind: type.to_s.split('_').first.to_sym, conditions: {} }
  end

  let(:source) do
    <<~RUBY
      # schema header
      class Post < ApplicationRecord
        before_save :set_slug,
                    if: :title_changed?
        after_create_commit :notify
        after_commit :ping, on: :update
        before_validation :clean, :trim
        after_save -> { touch }

        def set_slug; end
      end
    RUBY
  end

  it 'records the line range of the single call that declares each callback' do
    callbacks = [callback(:before_save, 'set_slug'), callback(:after_commit, 'notify'),
                 callback(:after_commit, 'ping'), callback(:before_validation, 'trim')]
    record = unit(source, callbacks)
    described_class.record(record)

    expect(record.metadata[:callbacks].map { |c| c[:declaration] })
      .to eq([{ 'line' => 3, 'end_line' => 4 }, { 'line' => 5, 'end_line' => 5 }, { 'line' => 6, 'end_line' => 6 },
              { 'line' => 7, 'end_line' => 7 }])
  end

  it 'leaves procs, framework callbacks and ambiguous or mistyped declarations without a site' do
    twice = source.sub("  def set_slug; end\n", "  before_save :set_slug\n")
    callbacks = [callback(:before_save, 'set_slug'), callback(:after_save, '#<Proc:0x1>'),
                 callback(:after_validation, '_ensure_no_duplicate_errors'), callback(:after_save, 'notify')]
    record = unit(twice, callbacks)
    described_class.record(record)

    expect(record.metadata[:callbacks].map { |c| c.key?(:declaration) }).to all(be(false))
  end

  it 'finds declarations inside an inlined concern block at their annotated lines' do
    concern = concern_block('Taggable', "included do\n  before_save :normalize_tags\nend\n")
    composite = "class Post < ApplicationRecord\nend\n#{concern}"
    record = unit(composite, [callback(:before_save, 'normalize_tags')])
    described_class.record(record)

    line = composite.lines.index { |l| l.include?('before_save :normalize_tags') } + 1
    expect(record.metadata[:callbacks].first[:declaration]).to eq('line' => line, 'end_line' => line)
  end

  it 'is idempotent on string-keyed callbacks read back from disk and ignores a source that does not parse' do
    callbacks = [{ 'type' => 'before_save', 'filter' => 'set_slug', 'declaration' => { 'line' => 99 } }]
    record = unit(source, callbacks)
    2.times { described_class.record(record) }
    expect(record.metadata[:callbacks].first['declaration']).to eq('line' => 3, 'end_line' => 4)

    broken = unit("class Post\n  before_save :x\n", [callback(:before_save, 'x')])
    described_class.record(broken)
    expect(broken.metadata[:callbacks].first).not_to have_key(:declaration)
  end
end
