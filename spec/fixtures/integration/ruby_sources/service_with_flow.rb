# frozen_string_literal: true

class PaymentProcessor
  def process(order)
    result = Gateway.charge(order.total_cents, order.payment_method)

    if result.success?
      order.confirm!
      ReceiptMailer.send_receipt(order).deliver_later
      { success: true, transaction_id: result.transaction_id }
    else
      ErrorTracker.report(result.error)
      { success: false, error: result.error }
    end
  rescue Gateway::TimeoutError => e
    ErrorTracker.report(e)
    RetryJob.perform_later(order.id)
    { success: false, error: 'timeout', retrying: true }
  end

  def refund(order)
    ActiveRecord::Base.transaction do
      order.update!(status: 'refunded')
      Gateway.refund(order.transaction_id)
      AuditLog.record(action: 'refund', order_id: order.id)
    end
  end
end
