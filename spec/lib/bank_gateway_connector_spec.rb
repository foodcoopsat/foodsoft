require_relative '../../spec_helper'

describe BankGatewayConnector do
  let(:bank_gateway) { create :bank_gateway, authorization: 'secret' }
  let(:bank_account) { create :bank_account, bank_gateway: bank_gateway }
  subject(:connector) { described_class.new(bank_gateway) }

  # What the connector sent to the gateway, as [request, payload].
  let(:sent) { [] }
  # Response of the gateway. +location+ is where the user has to continue at
  # the bank, +body+ the data of an import that could be done right away.
  let(:response) do
    instance_double(Net::HTTPResponse).tap do |res|
      allow(res).to receive(:code).and_return(status.to_s)
      allow(res).to receive(:message).and_return(message)
      allow(res).to receive(:header).and_return('Location' => location)
      allow(res).to receive(:body).and_return(body)
    end
  end
  let(:status) { 201 }
  let(:message) { 'Created' }
  let(:location) { 'https://bank.example.org/start' }
  let(:body) { '' }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http).and_return(response)
    allow(http).to receive(:request) { |request, payload| sent << [request, payload]; response }
  end

  def sent_request
    request, payload = sent.single
    [request, payload && JSON.parse(payload, symbolize_names: true)]
  end

  describe '#import_url' do
    it 'returns the location the user has to authenticate at' do
      expect(connector.import_url('https://foodcoop.example.org/callback', create(:user)))
        .to eq 'https://bank.example.org/start'

      request, payload = sent_request
      expect(request['Authorization']).to eq 'secret'
      expect(request['Content-Type']).to eq 'application/json'
      expect(payload).to include(callbackUri: 'https://foodcoop.example.org/callback')
    end

    it 'sends the accounts to import, continuing where the last import stopped' do
      bank_account.update!(import_continuation_point: 'ref-12')
      create :bank_transaction, bank_account: bank_account, date: Date.new(2024, 5, 4), external_id: 'ref-12'

      connector.import_url('https://foodcoop.example.org/callback', create(:user), reconfigure: true)

      _, payload = sent_request
      expect(payload).to include(reconfigure: true)
      expect(payload[:accounts].first).to include(
        iban: bank_account.iban,
        dateFrom: Date.new(2024, 5, 4).to_s,
        dateTo: '9999-12-31',
        entryReferenceFrom: 'ref-12'
      )
    end

    it 'imports right away when the gateway has the data already' do
      let(:status) { 200 }
      let(:message) { 'OK' }
      let(:location) { nil }
      let(:body) { { result: [{ account: { iban: bank_account.iban }, transactions: { booked: [] } }] }.to_json }

      it { expect(connector.import_url('https://foodcoop.example.org/callback', create(:user))).to eq 0 }
    end

    it 'refuses a location that is not an URL to follow' do
      let(:location) { 'ftp://bank.example.org/start' }

      it { expect { connector.import_url('https://foodcoop.example.org/callback', create(:user)) }.to raise_error(BankGatewayConnector::Error, /redirect/i) }
    end

    it 'raises the message of the gateway when it refuses' do
      let(:status) { 400 }
      let(:message) { 'Bad Request' }
      let(:body) { { message: 'no session' }.to_json }

      it { expect { connector.import_url(nil, nil) }.to raise_error(BankGatewayConnector::Error, 'Bad Request: no session') }
    end

    it 'raises when the gateway cannot be reached' do
      allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)

      expect { connector.import_url(nil, nil) }.to raise_error(BankGatewayConnector::Error, /within \d+ seconds/)
    end
  end

  describe '#import_unattended' do
    let(:status) { 200 }
    let(:message) { 'OK' }
    let(:location) { nil }
    let(:transaction) do
      { transactionId: '42', bookingDate: '2024-05-04',
        transactionAmount: { currency: 'EUR', amount: '-20.00' },
        creditorName: bank_account.name, remittanceInformationUnstructured: 'hello' }
    end

    before { bank_account }

    it 'does not pretend to be an interactive import' do
      connector.import_unattended

      _, payload = sent_request
      expect(payload).not_to have_key(:callbackUri)
      expect(payload).not_to have_key(:user)
    end

    it 'stores the transactions the gateway returns' do
      let(:body) { { result: [{ account: { iban: bank_account.iban }, transactions: { booked: [transaction] } }] }.to_json }

      expect(connector.import_unattended).to eq 1
      expect(bank_account.bank_transactions.find_by(external_id: '42').amount).to eq(-20)
    end

    it 'reports accounts that belong to another foodcoop' do
      other = create :bank_account
      let(:body) { { result: [{ account: { iban: other.iban }, transactions: { booked: [transaction] } }] }.to_json }

      it 'does not touch the account of another foodcoop' do
        expect { connector.import_unattended }
          .to raise_error(BankGatewayConnector::Error, /not known: #{other.iban}/)
        expect(other.reload.bank_transactions).to be_empty
      end
    end

    it 'raises when the gateway returns no accounts at all' do
      let(:body) { { result: [] }.to_json }

      expect { connector.import_unattended }.to raise_error(BankGatewayConnector::Error, /did not return any account data/i)
    end
  end

  describe '#handle_callback' do
    let(:status) { 200 }
    let(:message) { 'OK' }
    let(:transaction) do
      { transactionId: '43', bookingDate: '2024-05-05',
        transactionAmount: { currency: 'EUR', amount: '5.00' },
        debtorName: 'Eve', remittanceInformationUnstructured: 'dues' }
    end
    let(:body) { { result: [{ account: { iban: bank_account.iban }, transactions: { booked: [transaction] } }] }.to_json }

    it 'keeps the credentials of the foodcoop away from other sites' do
      expect { connector.handle_callback(result: 'https://evil.example.org/result') }
        .to raise_error(BankGatewayConnector::Error, /another site/i)
      expect { connector.handle_callback(result: nil) }
        .to raise_error(BankGatewayConnector::Error, /another site/i)
      expect(sent).to be_empty
    end

    it 'fetches the data the gateway refers to and imports it' do
      expect(connector.handle_callback(result: '/result/7f39')).to eq 1

      request, = sent_request
      expect(request.path).to eq '/result/7f39'
      expect(request['Authorization']).to eq 'secret'
      expect(bank_account.bank_transactions.find_by(external_id: '43').amount).to eq 5
    end

  end
end
