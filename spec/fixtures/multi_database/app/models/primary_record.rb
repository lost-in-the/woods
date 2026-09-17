# frozen_string_literal: true

class PrimaryRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary }
end
