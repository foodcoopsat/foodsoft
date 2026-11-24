require 'json'
require 'net/http'
require 'uri'

# Client for an external bank gateway service.
#
# The gateway is a service running outside of foodsoft which talks to the bank
# on our behalf (a full PSD2 account-information service needs its own
# certificate and eIDAS registration, so it does not live in the foodsoft
# process). It exposes a single endpoint:
#
#   POST /   body: { accounts: [...], callbackUri:, user:, reconfigure: }
#            -> 201 { Location: ... }   interactive: the user has to authenticate
#                                        with the bank and we redirect there
#            -> 200 { result: [...], count: N }   unattended: the data is already
#                                                 available and gets imported here
#   GET <path>  with an absolute path as returned in "Location" or "result", used
#               to fetch the data once the user is back from the bank
#
# Requests are authenticated with the opaque string stored in
# BankGateway#authorization, so foodsoft itself never sees bank credentials.
class BankGatewayConnector
  class Error < StandardError; end

  # The gateway may have to collect from several banks before it answers, so
  # the unattended import gets more time than the one a user waits for.
  UNATTENDED_TIMEOUT = 60
  READ_TIMEOUT = 15

  def initialize(bank_gateway)
    @bank_gateway = bank_gateway
  end

  # Runs without user interaction, using the login the gateway has stored for
  # itself. Used by the periodic import task.
  def import_unattended
    res = http_post(nil, nil, false, UNATTENDED_TIMEOUT)
    handle_result(res.body) || 0
  end

  # Starts an import and returns what the user has to do next.
  #
  # With a +user+, the gateway sends them to their bank to log in; without one,
  # it uses the login it has stored for the gateway as a whole and answers with
  # the data directly. That second case is handled here already and returns the
  # number of imported transactions instead of a URL, so the caller can tell
  # the two apart.
  #
  # @param callback_uri [String, nil] where the gateway redirects to after the
  #   user has logged in at the bank
  # @param user [User, nil] user whose login at the bank to use
  # @param reconfigure [Boolean] start the onboarding of a new login at the bank
  # @return [String, Integer] URL the user has to follow, or the number of
  #   transactions that were imported right away
  def import_url(callback_uri, user, reconfigure: false)
    res = http_post(callback_uri, user, reconfigure, READ_TIMEOUT)
    return handle_result(res.body) if res.header['Location'].blank?

    # The user is sent to this address of the gateway, so it has to be an URL
    # of a bank and not of something else.
    location = URI.parse(res.header['Location'])
    raise Error, I18n.t('bank_gateway_connector.invalid_redirect_url') unless %w[http https].include? location.scheme

    location.to_s
  end

  # Fetches the data the gateway referenced in the callback and imports it.
  #
  # @param params [Hash] params of the callback, holding the path to fetch
  # @return [Integer] number of imported transactions
  def handle_callback(params)
    res = http_get(params[:result])
    handle_result(res.body) || 0
  end

  private

  def handle_result(content)
    return nil if content.blank?

    data = JSON.parse(content, symbolize_names: true)
    result = data.fetch(:result, [])
    raise Error, I18n.t('bank_gateway_connector.no_accounts') if result.empty?

    result.sum do |account|
      bank_account = find_bank_account(account)
      bank_account ? BankAccountInformationImporter.new(bank_account).import_data!(account) : 0
    end
  end

  # Only accounts this gateway serves are imported: another foodcoop may well
  # use the same gateway, and its accounts are none of our business.
  # Looks up the foodcoop account a gateway account belongs to. When the
  # gateway knows more accounts than the foodcoop has set up, that is reported
  # instead of being ignored: the transactions of the unknown account would
  # silently never arrive.
  def find_bank_account(account)
    iban = account.dig(:account, :iban).to_s.delete(' ')
    bank_account = iban.present? ? @bank_gateway.bank_accounts.find_by(iban: iban) : @bank_gateway.bank_accounts.find_by(id: account.dig(:account, :id))
    raise Error, I18n.t('bank_gateway_connector.unknown_account', iban: iban.presence || account.dig(:account, :id)) if bank_account.nil?

    bank_account
  end

  def http_post(callback_uri, user, reconfigure, timeout)
    data = {
      accounts: @bank_gateway.bank_accounts.map do |ba|
        {
          id: ba.id,
          iban: ba.iban,
          dateFrom: ba.import_continuation_point && ba.last_transaction_date,
          dateTo: '9999-12-31',
          entryReferenceFrom: ba.import_continuation_point
        }
      end
    }
    data[:callbackUri] = callback_uri if callback_uri
    data[:user] = user.id.to_s if user
    data[:reconfigure] = true if reconfigure

    request(Net::HTTP::Post.new('/'), data.to_json, timeout)
  end

  # Fetches a result the gateway pointed at. It is a path on the gateway only:
  # following a URL of another site would send the credentials of the foodcoop
  # there.
  def http_get(path)
    uri = URI.parse(path.to_s)
    raise Error, I18n.t('bank_gateway_connector.invalid_result_url', host: gateway_host) unless uri.host.nil? && uri.path.present?

    request(Net::HTTP::Get.new(uri), nil, READ_TIMEOUT)
  rescue URI::InvalidURIError
    raise Error, I18n.t('bank_gateway_connector.invalid_result_url', host: gateway_host)
  end

  def gateway_host
    URI.parse(@bank_gateway.url.to_s).host
  end

  def request(request, body, timeout)
    url = URI.parse(@bank_gateway.url)
    request.initialize_http_header('Authorization' => @bank_gateway.authorization.to_s)
    request['Content-Type'] = 'application/json' if body
    res = Net::HTTP.start(url.hostname, url.port, use_ssl: url.scheme == 'https',
                          open_timeout: timeout, read_timeout: timeout) { |http| http.request(request, body) }
    raise error(res) unless res.code.to_i < 400

    res
  rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, Net::HTTPError => e
    Rails.logger.warn "BankGatewayConnector for '#{@bank_gateway.name}' failed: #{e.class}: #{e.message}"
    raise Error, I18n.t('bank_gateway_connector.timeout', timeout: timeout)
  end

  # The gateway reports details about what went wrong in its response body,
  # which is more helpful than the bare HTTP status when an import fails.
  def error(res)
    details = begin
      JSON.parse(res.body, symbolize_names: true)[:message]
    rescue StandardError
      nil
    end
    Error.new([res.message, details].compact_blank.join(': '))
  end
end
