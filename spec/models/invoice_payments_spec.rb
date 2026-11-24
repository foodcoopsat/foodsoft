require_relative '../spec_helper'

describe InvoicePayments do
  let(:gateway) { create :bank_gateway }
  let(:bank_account) { create :bank_account, iban: 'AT484230000155558000', bank_gateway: gateway }
  let(:supplier_category) { create :supplier_category, bank_account: bank_account }
  let(:supplier) { create :supplier, supplier_category: supplier_category, iban: 'AT611904300234573201' }
  let(:invoice) { create :invoice, supplier: supplier, number: 'R-2024-1', amount: 42.5 }

  subject(:invoice_payments) { described_class.new([invoice]) }

  describe '#bank_gateway' do
    it 'is the gateway of the bank account of the suppliers' do
      expect(invoice_payments.bank_gateway).to eq gateway
    end

    it 'is nil when no supplier is connected to a gateway' do
      bank_account.update! bank_gateway: nil

      expect(described_class.new([invoice]).bank_gateway).to be_nil
    end

    it 'refuses a selection paid from different gateways' do
      other = create :bank_gateway
      other_invoice = create :invoice, supplier: create(:supplier, supplier_category: create(:supplier_category,
                                                                                             bank_account: create(:bank_account,
                                                                                                                    bank_gateway: other,
                                                                                                                    iban: 'AT484230000155558001')))

      expect { described_class.new([invoice, other_invoice]).bank_gateway }
        .to raise_error(InvoicePayments::Error, I18n.t('finance.invoices.pay.multiple_bank_gateways'))
    end
  end

  describe '#payments' do
    let(:payment) { invoice_payments.payments.single }

    it 'pays the invoice from the bank account of its supplier category to the supplier' do
      expect(payment).to include(
        instructedAmount: { currency: FoodsoftConfig[:currency], amount: '42.5' },
        debtorAccount: { currency: FoodsoftConfig[:currency], iban: bank_account.iban },
        creditorName: supplier.name,
        creditorAccount: { iban: supplier.iban },
        remittanceInformationUnstructured: invoice.number
      )
    end

    it 'executes on the next working day' do
      expect(described_class.new([invoice], execution_date: Date.new(2024, 5, 4)).payments.single[:requestedExecutionDate])
        .to eq '2024-05-06' # Saturday -> Monday
      expect(described_class.new([invoice], execution_date: Date.new(2024, 5, 3)).payments.single[:requestedExecutionDate])
        .to eq '2024-05-03' # Friday stays Friday
    end

    it 'takes an explicit execution date' do
      invoice_payments.execution_date = Date.new(2024, 12, 20)

      expect(payment[:requestedExecutionDate]).to eq '2024-12-20'
    end
  end

  describe '#payable?' do
    it 'needs a payer and a creditor account' do
      expect(invoice_payments.payable?(invoice)).to be true
      expect(invoice_payments.payable?(create(:invoice, supplier: create(:supplier, iban: nil)))).to be false
    end
  end
end
