# frozen_string_literal: true

class DigestMailer < ActionMailer::Base
  before_action :load_digest, except: :weekly

  def daily
    mail(to: 'a@example.com', subject: 'daily', body: '')
  end

  def weekly
    mail(to: 'a@example.com', subject: 'weekly', body: '')
  end

  private

  def load_digest; end
end
