class Finance::BankGatewaysController < Finance::BaseController
  before_action :find_bank_gateway

  def callback
    count = @bank_gateway.connector.handle_callback params
    flash[:notice] = t('.notice', count: count)
    return redirect_to finance_bank_account_transactions_url(params[:bank_account]) if params[:bank_account]

    @bank_gateway.bank_accounts.each(&:assign_unlinked_transactions)
    redirect_to unpaid_finance_invoices_path
  end

  def import
    callback_uri = url_for(action: :callback, only_path: false, bank_account: params[:bank_account])
    reconfigure = params[:reconfigure]
    user = @bank_gateway.unattended_user ? nil : current_user
    return deny_access if reconfigure && !@bank_gateway.can_reconfigure?(current_user)

    location = @bank_gateway.connector.pay_and_import_url callback_uri, user, nil, reconfigure: reconfigure
    redirect_to location, status: :found
  end

  def pay
    return redirect_to unpaid_finance_invoices_path unless params[:invoices]

    ids = params[:invoices].map(&:to_i)
    invoices = Invoice.includes(:supplier).where(id: ids)

    payments = invoices.map do |i|
      {
        instructedAmount: {
          currency: 'EUR',
          amount: i.amount.to_s
        },
        debtorAccount: {
          iban: i.supplier.supplier_category.bank_account.iban
        },
        creditorName: i.supplier.name,
        creditorAccount: {
          iban: i.supplier.iban
        },
        remittanceInformationUnstructured: i.number
      }
    end

    callback_uri = url_for(action: :callback, only_path: false)
    user = @bank_gateway.unattended_user != current_user && current_user
    location = @bank_gateway.connector.pay_and_import_url callback_uri, user, { sepaCreditTransferPayments: payments }
    redirect_to location, status: :found
  end

  private

  def find_bank_gateway
    @bank_gateway = BankGateway.find(params[:id])
  end
end
