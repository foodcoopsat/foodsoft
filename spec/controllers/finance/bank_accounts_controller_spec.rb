require 'spec_helper'

describe Finance::BankAccountsController, type: :controller do
  render_views

  let(:admin) { create :admin }
  let(:bank_account) { create :bank_account }
  before { FoodsoftConfig.seed }
  before { login admin }

  describe 'import' do
    it { expect(get: :import, id: bank_account.id).to be_successful }

    it 'refuses an account whose transactions come from a bank gateway' do
      bank_account.update! bank_gateway: create(:bank_gateway)
      expect(get: :import, id: bank_account.id).to redirect_to(finance_bank_account_transactions_path(bank_account))
      expect(flash[:alert]).to eq I18n.t('finance.bank_accounts.import.no_import_method')
    end
  end
end
