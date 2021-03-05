class BankGatewayConnector
  def initialize(bank_gateway)
    @bank_gateway = bank_gateway
  end

  def import_unattended
    res = http_post nil, nil, nil, false
    handle_result res.body
  end

  def pay_and_import_url(callback_uri, user, payments, reconfigure: false)
    res = http_post callback_uri, user, payments, reconfigure
    res.header['Location']
  end

  def handle_callback(params)
    res = http_get params[:resultUri]
    handle_result res.body
  end

  private

  def handle_result(content)
    return nil if content.empty?

    ret = 0

    data = JSON.parse content, symbolize_names: true

    transactions = data.fetch(:transactions, [])
    transactions.each do |t|
      iban = t.fetch(:account, {}).fetch(:iban)

      ba = BankAccount.find_by_iban iban
      raise "Unknown BankAccount" unless ba

      baii = BankAccountInformationImporter.new(ba)
      ret += baii.import_data! t
    end

    ret
  end

  def http_post(callback_uri, user, payments, reconfigure)
    data = {
      accounts: @bank_gateway.bank_accounts.map do |ba|
        {
          iban: ba.iban,
          dateFrom: ba.last_transaction_date,
          dateTo: '9999-12-31',
          entryReferenceFrom: ba.import_continuation_point
        }
      end
    }
    data[:callbackUri] = callback_uri if callback_uri
    data[:payments] = payments if payments
    data[:user] = user.id.to_s if user
    data[:reconfigure] = true if reconfigure

    ret = Net::HTTP.post URI(@bank_gateway.url), data.to_json, 'Authorization' => @bank_gateway.authorization,
                                                               'Content-Type' => 'application/json'
    raise ret.message if ret.code.to_i >= 400

    ret
  end

  def http_get(url)
    raise 'Invalid URL' unless url.start_with?(@bank_gateway.url)

    ret = Net::HTTP.get_response URI(url)
    raise ret.message if ret.code.to_i >= 400

    ret
  end
end
