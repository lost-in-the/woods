# frozen_string_literal: true

class MultiInvoice < BillingRecord
  self.table_name = 'invoices'

  belongs_to :account, class_name: 'MultiAccount'
end
