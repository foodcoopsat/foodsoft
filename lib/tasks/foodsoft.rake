# put in here all foodsoft tasks
# => :environment loads the environment an gives easy access to the application
namespace :foodsoft do # rubocop:disable Metrics/BlockLength
  desc 'Finish ended orders'
  task finish_ended_orders: :environment do
    Order.finish_ended!
  end

  desc 'Notify users of upcoming tasks'
  task notify_upcoming_tasks: :environment do
    tasks = Task.where(done: false, due_date: 1.day.from_now.to_date)
    for task in tasks
      rake_say "Send notifications for #{task.name} to .."
      for user in task.users
        next unless user.settings.notify['upcoming_tasks']

        Mailer.deliver_now_with_user_locale user do
          Mailer.upcoming_tasks(user, task)
        end
      end
    end
  end

  desc 'Notify workgroup of upcoming weekly task'
  task notify_users_of_weekly_task: :environment do
    tasks = Task.where(done: false, due_date: 7.days.from_now.to_date)
    for task in tasks
      next if task.enough_users_assigned?

      workgroup = task.workgroup
      next unless workgroup

      rake_say "Notify workgroup: #{workgroup.name} for task #{task.name}"
      for user in workgroup.users
        next unless user.receive_email?

        Mailer.deliver_now_with_user_locale user do
          Mailer.not_enough_users_assigned(task, user)
        end
      end
    end
  end

  desc 'Create upcoming periodic tasks'
  task create_upcoming_periodic_tasks: :environment do
    for tg in PeriodicTaskGroup.all
      created_until = tg.create_tasks_for_upfront_days
      rake_say "created until #{created_until}"
    end
  end

  desc 'Parse incoming email on stdin (options: RECIPIENT=foodcoop.handling)'
  task parse_reply_email: :environment do
    FoodsoftMailReceiver.received ENV.fetch('RECIPIENT', nil), STDIN.read
  end

  desc 'Start STMP server for incoming email (options: SMTP_SERVER_PORT=2525, SMTP_SERVER_HOST=0.0.0.0)'
  task reply_email_smtp_server: :environment do
    port = ENV['SMTP_SERVER_PORT'].present? ? ENV['SMTP_SERVER_PORT'].to_i : 2525
    host = ENV.fetch('SMTP_SERVER_HOST', nil)
    rake_say "Started SMTP server for incoming email on port #{port}."
    server = FoodsoftMailReceiver.new(ports: port, hosts: host, max_processings: 1, logger: Rails.logger)
    server.start
    server.join
  end

  desc 'Import and assign bank transactions'
  task import_and_assign_bank_transactions: :environment do
    BankGateway.with_unattended_support.each do |bg|
      begin
        import_count = bg.connector.import_unattended
        rake_say "#{bg.name}: imported #{import_count}"
        next unless import_count

        bg.bank_accounts.each do |ba|
          assign_count = ba.assign_unlinked_transactions
          rake_say "#{ba.name}: assigned #{assign_count}"
        end
      rescue
        Mailer.deliver_now_with_user_locale bg.unattended_user do
          Mailer.failure_in_unattended_bank_import(bg)
        end
      end
    end

    BankAccount.find_each do |ba|
      importer = ba.find_connector
      next unless importer

      importer.load nil
      ok = importer.import nil
      next unless ok

      importer.finish
      assign_count = ba.assign_unlinked_transactions
      rake_say "#{ba.name}: imported #{importer.count}, assigned #{assign_count}"
    end
  end

  desc 'Prune attachments older than maximum age'
  task prune_old_attachments: :environment do
    if FoodsoftConfig[:attachment_retention_days]
      rake_say "Pruning attachments older than #{FoodsoftConfig[:attachment_retention_days]} days"
      ActiveStorage::Attachment.where('created_at < ?',
                                      FoodsoftConfig[:attachment_retention_days].days.ago).each do |attachment|
        rake_say attachment.inspect
        attachment.purge_later
      end
    else
      rake_say "Please configure your app_config.yml accordingly:\nattachment_retention_days: <number of days>"
    end
  end

  desc 'Retry sending failed message emails (default: last 24h, use ALL=1 to retry all, HOURS=x to specify hours)'
  task retry_failed_message_emails: :environment do
    rake_say "Retrying failed message emails..."
    
    if ENV['ALL'] == '1'
      failed_recipients = MessageRecipient.where(email_state: :failed)
      rake_say "Processing ALL failed message recipients (#{failed_recipients.count} found)"
    else
      hours = ENV['HOURS'] ? ENV['HOURS'].to_i : 24
      # Filter by messages' created_at since message_recipients doesn't have timestamps
      failed_recipients = MessageRecipient
        .where(email_state: :failed)
        .joins(:message)
        .where('messages.created_at >= ?', hours.hours.ago)
      rake_say "Processing failed message recipients from last #{hours}h (#{failed_recipients.count} found)"
      rake_say "Use ALL=1 to retry all failed emails, HOURS=x to specify hours"
    end
    
    success_count = 0
    failure_count = 0
    
    failed_recipients.each do |recipient|
      message = recipient.message
      user = recipient.user
      
      begin
        Mailer.deliver_now_with_user_locale user do
          MessagesMailer.foodsoft_message(user, message)
        end
        recipient.update(email_state: :sent)
        success_count += 1
        rake_say "✓ Successfully resent email for message #{message.id} to #{user.email}"
      rescue => e
        failure_count += 1
        recipient.update(email_state: :failed)
        rake_say "✗ Failed to resend email for message #{message.id} to #{user.email}: #{e.message}"
        Rails.logger.error("Failed to resend message #{message.id} to #{user.email}: #{e.class} - #{e.message}")
      end
    end
    
    rake_say "\nRetry complete: #{success_count} succeeded, #{failure_count} failed"
  end

  desc 'Retry sending failed order result emails (default: last 24h, use ALL=1 to retry all, HOURS=x to specify hours)'
  task retry_failed_order_emails: :environment do
    rake_say "Retrying failed order result emails..."
    
    # Find failed order result emails from MailDeliveryStatus
    if ENV['ALL'] == '1'
      failed_statuses = MailDeliveryStatus.where("message LIKE '%order_result%'")
      rake_say "Processing ALL failed order result emails (#{failed_statuses.count} found)"
    else
      hours = ENV['HOURS'] ? ENV['HOURS'].to_i : 24
      failed_statuses = MailDeliveryStatus.where("message LIKE '%order_result%'").where('created_at >= ?', hours.hours.ago)
      rake_say "Processing failed order result emails from last #{hours}h (#{failed_statuses.count} found)"
      rake_say "Use ALL=1 to retry all failed emails, HOURS=x to specify hours"
    end
    
    success_count = 0
    failure_count = 0
    
    failed_statuses.each do |status|
      # Try to find the user by email
      user = User.find_by(email: status.email)
      
      if user.nil?
        failure_count += 1
        rake_say "✗ Could not find user with email #{status.email}"
        next
      end
      
      # Try to find the order from the error message
      # The error message might contain order information
      order = nil
      if status.message =~ /order_id:?\b(\d+)\b/i
        order = Order.find_by(id: $1)
      end
      
      begin
        Mailer.deliver_now_with_user_locale user do
          Mailer.order_result(user, order)
        end
        status.destroy
        success_count += 1
        rake_say "✓ Successfully resent order result email to #{user.email}"
      rescue => e
        failure_count += 1
        Rails.logger.error("Failed to resend order result to #{user.email}: #{e.class} - #{e.message}")
        rake_say "✗ Failed to resend order result to #{user.email}: #{e.message}"
      end
    end
    
    rake_say "\nRetry complete: #{success_count} succeeded, #{failure_count} failed"
  end

  desc 'Send test email to verify email configuration'
  task send_test_email: :environment do
    email = ENV['TEST_EMAIL']
    if email.nil? || email.empty?
      puts "Usage: TEST_EMAIL=user@example.com bundle exec rake foodsoft:send_test_email"
      exit 1
    end
    
    user = User.first
    if user.nil?
      puts "No users found. Please create a user first."
      exit 1
    end
    
    puts "Sending test email to #{email}..."
    
    begin
      Mailer.deliver_now do
        Mailer.test_email(user, email)
      end
      puts "✓ Test email sent successfully to #{email}"
    rescue => e
      puts "✗ Failed to send test email: #{e.message}"
      Rails.logger.error("Failed to send test email: #{e.class} - #{e.message}")
      exit 1
    end
  end
end

# Helper
def rake_say(message)
  puts message unless Rake.application.options.silent
end
