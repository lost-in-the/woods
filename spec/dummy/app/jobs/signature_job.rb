# frozen_string_literal: true

class SignatureJob < ActiveJob::Base
  def perform(user_id, values = [1, 2], *rest, required:, notify: true, **options, &block); end
end
