class SendOrderToSupplierJob < ApplicationJob
  # Retry email delivery on network-related failures
  retry_on Net::ReadTimeout, wait: :exponentially_longer, attempts: 5
  retry_on Net::OpenTimeout, wait: :exponentially_longer, attempts: 5

  def perform(order)
    begin
      Mailer.deliver_now_with_default_locale do
        Mailer.order_result_supplier(order.created_by, order)
      end
    rescue StandardError => e
      Rails.logger.error("Failed to deliver order_result_supplier email: #{e.class} - #{e.message}")
      # Don't update last_sent_mail if delivery failed
      return
    end
    order.update!(last_sent_mail: Time.now)
  end
end
