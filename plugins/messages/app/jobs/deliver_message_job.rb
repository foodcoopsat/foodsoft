class DeliverMessageJob < ApplicationJob
  # Retry email delivery on network-related failures with exponential backoff
  # We use a broader rescue in perform() for any email-related exceptions
  retry_on Net::ReadTimeout, wait: :exponentially_longer, attempts: 5
  retry_on Net::OpenTimeout, wait: :exponentially_longer, attempts: 5

  def perform(message)
    message.message_recipients.each do |message_recipient|
      # Skip the action if email_state is :sent
      next if message_recipient.email_state == 'sent'

      recipient = message_recipient.user
      if recipient.receive_email?
        begin
          Mailer.deliver_now_with_user_locale recipient do
            MessagesMailer.foodsoft_message(recipient, message)
          end
          message_recipient.update_attribute :email_state, :sent
        rescue => e
          # Log the error but don't let one failed email stop the whole job
          Rails.logger.error("Failed to deliver message #{message.id} to recipient #{recipient.id} (#{recipient.email}): #{e.class} - #{e.message}")
          # Mark as failed but continue with other recipients
          message_recipient.update_attribute :email_state, :failed
        end
      else
        message_recipient.update_attribute :email_state, :skipped
      end
    end
    # Don't raise error - let failed emails be tracked separately
    # This ensures other successful deliveries aren't lost
  end
end
