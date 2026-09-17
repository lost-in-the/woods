# frozen_string_literal: true

class MultiReplicaAccount < BillingRecord
  self.table_name = 'accounts'

  has_many :invoices, class_name: 'MultiInvoice', foreign_key: :account_id
end
