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
      expect(connector).to have_received(:import_url) do |callback_uri, user, reconfigure:|
        expect(callback_uri).to eq "http://test.host/#{FoodsoftConfig[:default_scope]}/finance/bank_gateways/#{bank_gateway.id}/callback?bank_account=#{bank_account.id}"
        expect(user).to eq finance_user
        expect(reconfigure).to be false
      end
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
        get_with_defaults :import, id: bank_gateway.id, reconfigure: 'true'

        expect(response).to redirect_to(root_path)
        expect(connector).not_to have_received(:import_url)
      end

      it 'is allowed for the unattended user' do
        unattended_user = create :user, :role_finance
        bank_gateway.update! unattended_user: unattended_user
        login unattended_user
        allow(connector).to receive(:import_url).and_return('https://bank.example.org/start')

        get_with_defaults :import, id: bank_gateway.id, reconfigure: 'true'

        expect(connector).to have_received(:import_url) do |_callback_uri, user, reconfigure:|
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
