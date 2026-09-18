# frozen_string_literal: true

class MultiSubscription < ReportingRecord
  self.table_name = 'subscriptions'

  belongs_to :account, class_name: 'MultiAccount'
  belongs_to :subscriber, class_name: 'MultiReplicaAccount'
end
