class Finance::BankGatewaysController < Finance::BaseController
  before_action :find_bank_gateway

  def callback
    count = @bank_gateway.connector.handle_callback(params)
    redirect_back fallback_location: finance_bank_accounts_url, notice: t('.notice', count: count)
  rescue StandardError => e
    redirect_back fallback_location: finance_bank_accounts_url, alert: t('errors.general_msg', msg: e.message)
  end

  def import
    bank_account = BankAccount.find_by(id: params[:bank_account])
    callback_uri = url_for(action: :callback, only_path: false, bank_account: bank_account&.id)
    reconfigure = params[:reconfigure].present?
    return deny_access if reconfigure && !@bank_gateway.can_reconfigure?(current_user)

    # An unattended user on the gateway means the import runs from the
    # periodic task instead of interactively, so no bank login is shown.
    user = @bank_gateway.unattended_user ? nil : current_user
    location = @bank_gateway.connector.import_url(callback_uri, user, reconfigure: reconfigure)
    return redirect_to finance_bank_account_transactions_url(bank_account), notice: t('.notice', count: location) if location.is_a?(Integer)

    redirect_to location, status: :found, allow_other_host: true
  rescue StandardError => e
    redirect_to finance_bank_account_transactions_url(bank_account), alert: t('errors.general_msg', msg: e.message)
  end

  private

  def find_bank_gateway
    @bank_gateway = BankGateway.find(params[:id])
  end
end
