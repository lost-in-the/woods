# frozen_string_literal: true

class BillingRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :billing }
end
