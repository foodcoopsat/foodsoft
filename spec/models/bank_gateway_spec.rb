require_relative '../spec_helper'

describe BankGateway do
  let(:bank_gateway) { create :bank_gateway }

  describe '#connector' do
    it { expect(bank_gateway.connector).to be_a BankGatewayConnector }
  end

  describe '#can_reconfigure?' do
    let(:unattended_user) { create :user }
    let(:admin) { create :admin }
    let(:other_user) { create :user }
    let(:bank_gateway) { create :bank_gateway, unattended_user: unattended_user }

    it 'allows the admin' do
      expect(bank_gateway).to be_can_reconfigure admin
    end

    it 'allows the unattended user' do
      expect(bank_gateway).to be_can_reconfigure unattended_user
    end

    it 'denies anyone else' do
      expect(bank_gateway).not_to be_can_reconfigure other_user
    end
  end

  describe '#pending_payments' do
    it { expect(bank_gateway.pending_payments).to eq [] }

    it 'keeps the payments that have been handed to the gateway' do
      bank_gateway.update! pending_payments: [{ creditorAccount: { iban: 'AT611904300234573201' } }]

      expect(bank_gateway.reload.pending_payments).to eq [{ 'creditorAccount' => { 'iban' => 'AT611904300234573201' } }]
    end
  end
end
