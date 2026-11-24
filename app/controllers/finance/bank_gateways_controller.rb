class Finance::BankGatewaysController < Finance::BaseController
  before_action :find_bank_gateway

  def callback
    count = @bank_gateway.connector.handle_callback(params)
    # The invoices of a transfer are paid once the bank has confirmed them, and
    # not when the bank statement turns up with the next import.
    paid = mark_invoices_as_paid
    return redirect_to unpaid_finance_invoices_url, notice: t('.paid', count: paid, bank_gateway: @bank_gateway.name) if paid

    redirect_back fallback_location: finance_bank_accounts_url, notice: t('.notice', count: count)
  rescue StandardError => e
    redirect_back fallback_location: finance_bank_accounts_url, alert: t('errors.general_msg', msg: e.message)
  end

  # Starts an import at the gateway, handing over the transfers of the invoices
  # selected on the unpaid invoices page along the way. Without an account to
  # import into there is nothing to do here: the import cannot be started on its
  # own, it runs from the periodic task which reports a failure of its own.
  #
  # The user logs in at their bank, unless a user is configured on the gateway
  # for the periodic task, in which case the gateway answers with the data right
  # away.
  def import
    bank_account = BankAccount.find_by(id: params[:bank_account])
    return redirect_to finance_bank_accounts_url, alert: t('.no_import_method') unless bank_account

    callback_uri = url_for(action: :callback, only_path: false, bank_account: bank_account.id)
    reconfigure = params[:reconfigure].present?
    return deny_access if reconfigure && !@bank_gateway.can_reconfigure?(current_user)

    # With a user configured on the gateway the import runs unattended from
    # the periodic task, so the gateway uses its own login at the bank.
    user = @bank_gateway.unattended_user ? nil : current_user
    payments = gateway_payments
    location = @bank_gateway.connector.import_url(callback_uri, user, payments: payments, reconfigure: reconfigure)
    return redirect_to finance_bank_account_transactions_url(bank_account), notice: t('.notice', count: location) if location.is_a?(Integer)

    # What has been handed over is remembered until the bank has confirmed it --
    # the bank statement with the transfer may well arrive after the next import.
    @bank_gateway.update! pending_payments: payments if payments.present?
    redirect_to location, status: :found, allow_other_host: true
  rescue StandardError => e
    redirect_to finance_bank_account_transactions_url(bank_account), alert: t('errors.general_msg', msg: e.message)
  end

  private

  # The transfers of the invoices selected on the unpaid invoices page which this
  # gateway pays from. Invoices of another gateway are left out, they need an
  # import of their own -- a selection paid from two bank accounts cannot be
  # handed over at once.
  #
  # @return [Array<Hash>] one transfer per invoice, empty when none was selected
  def gateway_payments
    ids = params[:invoices]
    return [] if ids.blank?

    ids = ids.split(',') if ids.is_a?(String)
    invoices = Invoice.unpaid.includes(supplier: { supplier_category: :bank_account }).where(id: ids).to_a
    payments = InvoicePayments.new(invoices.select { |invoice| invoice.supplier&.supplier_category&.bank_account&.bank_gateway_id == @bank_gateway.id })
    payments.payable? ? payments.payments : []
  end

  # An invoice is only marked as paid when this gateway has been handed a
  # transfer for its supplier, so the callback cannot be used for just any
  # invoice.
  def mark_invoices_as_paid
    return nil if params[:invoices].blank?

    invoices = Invoice.unpaid.where(id: params[:invoices]).where(supplier: Supplier.where(iban: handed_over_ibans))
    return nil if invoices.empty?

    link = FinancialLink.first_unused_or_create
    count = 0
    invoices.find_each do |invoice|
      invoice.update! paid_on: Date.current, financial_link: link
      count += 1
    end
    return nil if count.zero?

    # The bank has confirmed the transfer, so it is not handed over a second time.
    @bank_gateway.update! pending_payments: nil
    count
  end

  # The suppliers the transfers on their way were made out to.
  def handed_over_ibans
    @bank_gateway.pending_payments.to_a.filter_map { |payment| payment.dig('creditorAccount', 'iban') }
  end

  def find_bank_gateway
    @bank_gateway = BankGateway.find(params[:id])
  end
end
