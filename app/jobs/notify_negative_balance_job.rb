class NotifyNegativeBalanceJob < ApplicationJob
  # Retry email delivery on network-related failures
  retry_on Net::ReadTimeout, wait: :exponentially_longer, attempts: 5
  retry_on Net::OpenTimeout, wait: :exponentially_longer, attempts: 5

  def perform(ordergroup, transaction)
    ordergroup.users.each do |user|
      next unless user.settings.notify['negative_balance']

      begin
        Mailer.deliver_now_with_user_locale user do
          Mailer.negative_balance(user, transaction)
        end
      rescue StandardError => e
        Rails.logger.error("Failed to deliver negative_balance email to #{user.email}: #{e.class} - #{e.message}")
      end
    end
  end
end
