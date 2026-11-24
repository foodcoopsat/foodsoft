require_relative '../../spec_helper'

describe Finance::BankGatewaysController do
  let(:finance_user) { create :user, :role_finance }
  let(:bank_gateway) { create :bank_gateway }
  let(:bank_account) { create :bank_account, bank_gateway: bank_gateway }
  let(:connector) { instance_double(BankGatewayConnector) }

  before do
    login finance_user
    allow(bank_gateway).to receive(:connector).and_return(connector)
  end

  describe 'GET import' do
    it 'redirects to the bank so the user can authenticate' do
      allow(connector).to receive(:import_url).and_return('https://bank.example.org/start')

      get_with_defaults :import, id: bank_gateway.id, bank_account: bank_account.id

      expect(response).to redirect_to('https://bank.example.org/start')
      expect(connector).to have_received(:import_url) do |callback_uri, user, payments: nil, reconfigure:|
        expect(callback_uri).to eq callback_finance_bank_gateway_url(bank_gateway, bank_account: bank_account.id)
        expect(user).to eq finance_user
        expect(reconfigure).to be false
      end
    end

    it 'is refused without an account to import into' do
      get_with_defaults :import, id: bank_gateway.id

      expect(response).to redirect_to(finance_bank_accounts_path)
      expect(flash[:alert]).to eq I18n.t('finance.bank_accounts.import.no_import_method')
      expect(connector).not_to have_received(:import_url)
    end

    it 'hands over the payments of the selected invoices' do
      category = create :supplier_category
      category.bank_account.update! bank_gateway: bank_gateway, iban: 'DE14370400440532013000'
      invoice = create :invoice, supplier: create(:supplier, supplier_category: category, iban: 'DE12345678901234567890')
      allow(connector).to receive(:import_url).and_return('https://bank.example.org/start')

      get_with_defaults :import, id: bank_gateway.id, bank_account: bank_account.id, invoices: [invoice.id]

      expect(connector).to have_received(:import_url) do |_callback_uri, _user, payments:, reconfigure:|
        expect(reconfigure).to be false
        expect(payments.length).to eq 1
        payment = payments.first
        expect(payment[:debtorAccount][:iban]).to eq 'DE14370400440532013000'
        expect(payment[:creditorAccount][:iban]).to eq 'DE12345678901234567890'
        expect(payment[:instructedAmount][:amount]).to eq invoice.amount.to_s
      end
      expect(bank_gateway.reload.pending_payments.single['creditorAccount']).to eq 'iban' => 'DE12345678901234567890'
    end

    it 'marks the handed invoices as paid once the bank confirmed them' do
      category = create :supplier_category
      category.bank_account.update! bank_gateway: bank_gateway, iban: 'DE14370400440532013000'
      invoice = create :invoice, supplier: create(:supplier, supplier_category: category, iban: 'DE12345678901234567890')
      bank_gateway.update! pending_payments: [{ 'creditorAccount' => { 'iban' => 'DE12345678901234567890' } }]
      allow(connector).to receive(:handle_callback).and_return(0)

      get_with_defaults :callback, id: bank_gateway.id, invoices: [invoice.id]

      expect(invoice.reload.paid_on).to eq Date.current
      expect(bank_gateway.reload.pending_payments).to be_nil
      expect(flash[:notice]).to eq I18n.t('finance.bank_gateways.callback.paid', count: 1, bank_gateway: bank_gateway.name)
    end

    it 'leaves invoices alone that were not handed to the gateway' do
      invoice = create :invoice, supplier: create(:supplier, iban: 'DE12345678901234567890')
      bank_gateway.update! pending_payments: [{ 'creditorAccount' => { 'iban' => 'DE99999999999999999999' } }]
      allow(connector).to receive(:handle_callback).and_return(0)

      get_with_defaults :callback, id: bank_gateway.id, invoices: [invoice.id]

      expect(invoice.reload.paid_on).to be_nil
      expect(response).to redirect_to(finance_bank_accounts_path)
    end

    it 'imports right away when the gateway has the data already' do
      allow(connector).to receive(:import_url).and_return(7)

      get_with_defaults :import, id: bank_gateway.id, bank_account: bank_account.id

      expect(response).to redirect_to(finance_bank_account_transactions_path(bank_account))
      expect(flash[:notice]).to eq I18n.t('finance.bank_gateways.callback.notice', count: 7)
    end

    it 'alerts when the gateway is not reachable' do
      allow(connector).to receive(:import_url).and_raise(BankGatewayConnector::Error, 'gateway down')

      get_with_defaults :import, id: bank_gateway.id, bank_account: bank_account.id

      expect(response).to redirect_to(finance_bank_account_transactions_path(bank_account))
      expect(flash[:alert]).to eq I18n.t('errors.general_msg', msg: 'gateway down')
    end

    describe 'reconfigure' do
      it 'is refused for a user the gateway is not configured for' do
        get_with_defaults :import, id: bank_gateway.id, bank_account: bank_account.id, reconfigure: 'true'

        expect(response).to redirect_to(root_path)
        expect(connector).not_to have_received(:import_url)
      end

      it 'is allowed for the unattended user' do
        unattended_user = create :user, :role_finance
        bank_gateway.update! unattended_user: unattended_user
        login unattended_user
        allow(connector).to receive(:import_url).and_return('https://bank.example.org/start')

        get_with_defaults :import, id: bank_gateway.id, bank_account: bank_account.id, reconfigure: 'true'

        expect(connector).to have_received(:import_url) do |_callback_uri, user, payments: nil, reconfigure:|
          expect(user).to be nil
          expect(reconfigure).to be true
        end
      end
    end
  end

  describe 'GET callback' do
    it 'imports the data the gateway has collected and assigns the transactions' do
      allow(connector).to receive(:handle_callback).and_return(3)

      get_with_defaults :callback, id: bank_gateway.id, result: '/result/7f39'

      expect(response).to redirect_to(finance_bank_accounts_path)
      expect(flash[:notice]).to eq I18n.t('finance.bank_gateways.callback.notice', count: 3)
      expect(connector).to have_received(:handle_callback) do |params|
        expect(params[:result]).to eq '/result/7f39'
      end
    end

    it 'alerts when importing failed' do
      allow(connector).to receive(:handle_callback).and_raise(BankGatewayConnector::Error, 'unknown account')

      get_with_defaults :callback, id: bank_gateway.id, result: '/result/7f39'

      expect(flash[:alert]).to eq I18n.t('errors.general_msg', msg: 'unknown account')
    end
  end
end
