# frozen_string_literal: true

class ReportingRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :reporting }
end
