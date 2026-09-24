class NotifyFinishedOrderJob < ApplicationJob
  # Retry email delivery on network-related failures with exponential backoff
  # We use a broader rescue in perform() for any email-related exceptions
  retry_on Net::ReadTimeout, wait: :exponentially_longer, attempts: 5
  retry_on Net::OpenTimeout, wait: :exponentially_longer, attempts: 5

  def perform(order)
    order.group_orders.each do |group_order|
      next unless group_order.ordergroup

      group_order.ordergroup.users.each do |user|
        next unless user.settings.notify['order_finished']

        begin
          Mailer.deliver_now_with_user_locale user do
            Mailer.order_result(user, group_order)
          end
        rescue StandardError => e
          # Log the error but don't let one failed email stop the whole job
          Rails.logger.error("Failed to deliver order_result email to #{user.email}: #{e.class} - #{e.message}")
        end
      end
    end
  end
end
