require_relative '../spec_helper'
require 'rake'

describe Rake::Task do
  describe 'foodsoft:import_and_assign_bank_transactions' do
    before do
      Foodsoft::Application.load_tasks unless described_class.task_defined?('foodsoft:import_and_assign_bank_transactions')
      described_class['foodsoft:import_and_assign_bank_transactions'].reenable
    end

    it 'imports and assigns the accounts of gateways with an unattended user' do
      unattended_user = create :user
      bank_gateway = create :bank_gateway, unattended_user: unattended_user
      bank_account = create :bank_account, bank_gateway: bank_gateway
      connector = instance_double(BankGatewayConnector)
      allow(BankGatewayConnector).to receive(:new).with(bank_gateway).and_return(connector)
      allow(connector).to receive(:import_unattended).and_return(2)
      allow(bank_account).to receive(:assign_unlinked_transactions).and_return(1)

      described_class['foodsoft:import_and_assign_bank_transactions'].invoke

      expect(connector).to have_received(:import_unattended)
      expect(bank_account).to have_received(:assign_unlinked_transactions)
    end

    it 'skips gateways without an unattended user' do
      create :bank_gateway, url: 'http://127.0.0.1:1/'

      expect { described_class['foodsoft:import_and_assign_bank_transactions'].invoke }.not_to raise_error
    end

    it 'tells the user of a gateway when its import failed, and carries on with the others' do
      failing = create :bank_gateway, unattended_user: create(:user, :role_finance)
      working = create :bank_gateway, unattended_user: create(:user, :role_finance)
      broken = instance_double(BankGatewayConnector)
      good = instance_double(BankGatewayConnector)
      allow(BankGatewayConnector).to receive(:new).with(failing).and_return(broken)
      allow(BankGatewayConnector).to receive(:new).with(working).and_return(good)
      allow(broken).to receive(:import_unattended).and_raise(BankGatewayConnector::Error, 'bank said no')
      allow(good).to receive(:import_unattended).and_return(1)

      expect { described_class['foodsoft:import_and_assign_bank_transactions'].invoke }
        .to change { ActionMailer::Base.deliveries.size }.by(1)

      expect(good).to have_received(:import_unattended)
      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq [failing.unattended_user.email]
      expect(mail.subject).to eq I18n.t('mailer.bank_import_failed.subject', bank_gateway: failing.name)
      expect(mail.body.encoded).to include 'bank said no'
    end
  end
end
