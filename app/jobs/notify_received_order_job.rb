class NotifyReceivedOrderJob < ApplicationJob
  # Retry email delivery on network-related failures
  retry_on Net::ReadTimeout, wait: :exponentially_longer, attempts: 5
  retry_on Net::OpenTimeout, wait: :exponentially_longer, attempts: 5

  def perform(order)
    order.group_orders.each do |group_order|
      next unless group_order.ordergroup

      group_order.ordergroup.users.each do |user|
        next unless user.settings.notify['order_received']

        begin
          Mailer.deliver_now_with_user_locale user do
            Mailer.order_received(user, group_order)
          end
        rescue StandardError => e
          Rails.logger.error("Failed to deliver order_received email to #{user.email}: #{e.class} - #{e.message}")
        end
      end
    end
  end
end
