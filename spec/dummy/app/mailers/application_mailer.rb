# frozen_string_literal: true

# Base mailer with a default sender so mailer extraction sees defaults.
class ApplicationMailer < ActionMailer::Base
  default from: 'forum@example.com'
  layout 'mailer'
end
