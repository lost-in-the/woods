# frozen_string_literal: true

class StableMailer < ActionMailer::Base
  sender = if ENV['MAILER_DEFAULT_KIND'] == 'proc'
             proc { raise 'default must not execute during extraction' }
           else
             -> { raise 'default must not execute during extraction' }
           end
  default from: sender, reply_to: 'literal-0xdeadbeef@example.test', cc: ['copy@example.test']

  class ObjectCallback
    def before(_mailer)
      raise 'object callback must not execute during extraction'
    end
  end

  before_action ObjectCallback.new
  before_action :prepare
  around_action(proc { raise 'callback must not execute during extraction' })
  after_action :finish

  def zeta; end
  def beta; end
  def epsilon; end
  def alpha; end
  def gamma; end
  def delta; end

  private

  def prepare; end
  def finish; end
end
