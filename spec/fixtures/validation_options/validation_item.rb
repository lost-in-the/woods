# frozen_string_literal: true

class ValidationItem < ActiveRecord::Base
  validates :status, inclusion: { in: ->(_record) { raise 'inclusion must not execute' } },
                     unless: -> { raise 'condition must not execute' }
  validates :status, exclusion: { in: proc { raise 'exclusion must not execute' } }, on: :update
  validates :status, presence: { message: proc { raise 'message must not execute' } }, if: :ready?
  validates :status, inclusion: { in: %w[ready pending], message: 'literal 0xdeadbeef' }, allow_nil: true

  def description
    'before'
  end

  def ready?
    raise 'condition must not execute'
  end
end
