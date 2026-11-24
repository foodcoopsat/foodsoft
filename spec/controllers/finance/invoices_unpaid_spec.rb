require_relative '../../spec_helper'

describe Finance::InvoicesController do
  let(:finance_user) { create :user, :role_finance }
  let(:bank_gateway) { create :bank_gateway }
  let(:bank_account) { create :bank_account, bank_gateway: bank_gateway }
  let(:supplier_category) { create :supplier_category, bank_account: bank_account }
  let(:supplier) { create :supplier, supplier_category: supplier_category, iban: 'AT611904300234573201' }
  let(:invoice) { create :invoice, supplier: supplier, created_by: finance_user }

  before { login finance_user }

  describe 'GET unpaid' do
    it 'offers to pay through the gateway of the supplier' do
      invoice

      get_with_defaults :unpaid

      expect(assigns(:bank_gateway)).to eq bank_gateway
    end

    it 'offers no payment when no supplier is connected to a gateway' do
      bank_account.update! bank_gateway: nil
      invoice

      get_with_defaults :unpaid

      expect(assigns(:bank_gateway)).to be_nil
    end

    it 'leaves invoices of a gateway without a bank account unoffered' do
      bank_account.update! bank_gateway: nil
      other = create :bank_gateway
      create :bank_account, bank_gateway: other
      invoice

      get_with_defaults :unpaid

      expect(assigns(:bank_gateway)).to be_nil
    end
  end
end
