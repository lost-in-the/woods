# frozen_string_literal: true

class Order < ApplicationRecord
  include Auditable
  extend Searchable

  STATUSES = %w[pending confirmed shipped delivered cancelled].freeze
  MAX_ITEMS = 100

  belongs_to :customer
  has_many :line_items, dependent: :destroy
  has_one :shipment

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_cents, numericality: { greater_than_or_equal_to: 0 }

  before_save :recalculate_total
  after_create :notify_warehouse

  scope :active, -> { where.not(status: 'cancelled') }
  scope :recent, -> { where('created_at > ?', 30.days.ago) }

  def confirm!
    update!(status: 'confirmed')
    OrderMailer.confirmation(self).deliver_later
  end

  def cancel! # rubocop:disable Naming/PredicateMethod
    return false if status == 'shipped'

    update!(status: 'cancelled')
    RefundService.process(self)
    true
  end

  def self.find_by_reference(ref)
    where(reference: ref).first
  end

  private

  def recalculate_total
    self.total_cents = line_items.sum(:price_cents)
  end

  def notify_warehouse
    WarehouseJob.perform_later(id)
  end
end
