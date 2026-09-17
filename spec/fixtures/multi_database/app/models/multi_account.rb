# frozen_string_literal: true

class MultiAccount < PrimaryRecord
  self.table_name = 'accounts'

  has_many :invoices, class_name: 'MultiInvoice', foreign_key: :account_id
  has_many :subscriptions, class_name: 'MultiSubscription', foreign_key: :account_id
  has_many :subscribers, through: :subscriptions, source: :subscriber
end
