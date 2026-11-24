# Builds the transfers the bank gateway expects for paying invoices, and finds
# out which gateway is responsible for a set of them.
#
# A transfer can only be made from one bank account, so all invoices of a
# payment must be paid by the same gateway: the one serving the bank account
# configured on the supplier category of their supplier.
class InvoicePayments
  Error = Class.new(StandardError)

  # Allows the execution date to be overridden, so a foodcoop can decide when
  # its suppliers get paid.
  attr_writer :execution_date

  def initialize(invoices, execution_date: nil)
    @invoices = invoices.to_a
    @execution_date = execution_date
  end

  # Whether a set of invoices can be handed over as transfers at all: each of
  # them needs both accounts of a transfer, the one it goes out from and the one
  # it goes to.
  #
  # @return [Boolean]
  def self.payable?(invoices)
    new(invoices).payable?
  end

  # @return [BankGateway, nil] the gateway the invoices can be paid with
  def self.bank_gateway_for(invoices)
    new(invoices).bank_gateway
  end

  # @return [Boolean] whether all of the invoices can be paid this way
  def payable?
    @invoices.present? && @invoices.all? { |invoice| payable?(invoice) }
  end

  # The gateway all of the invoices go out from.
  #
  # @return [BankGateway, nil] nil when none of them is paid by a gateway
  def bank_gateway
    return nil if @invoices.empty?

    gateways = @invoices.map { |invoice| gateway_of(invoice) }.compact.uniq
    return nil if gateways.empty?
    raise Error, I18n.t('finance.invoices.pay.multiple_bank_gateways') if gateways.length > 1

    gateways.first
  end

  # A single transfer per invoice, so the remittance information stays
  # unambiguous and each invoice can be traced back to its own payment.
  #
  # @return [Array<Hash>] transfers in the format of the gateway, one per invoice
  def payments
    @invoices.map { |invoice| payment_for(invoice) }
  end

  # @return [Boolean] whether this single invoice can be paid by a gateway
  def payable?(invoice)
    payer_iban(invoice).present? && invoice.supplier.iban.present?
  end

  private

  def payment_for(invoice)
    payment = {
      instructedAmount: { currency: FoodsoftConfig[:currency], amount: invoice.amount.to_s },
      debtorAccount: { currency: FoodsoftConfig[:currency], iban: payer_iban(invoice) },
      creditorName: invoice.supplier.name,
      creditorAccount: { iban: invoice.supplier.iban }
    }
    # Execute on the next working day: banks don't process transfers over the
    # weekend, and asking for today may be refused after the cut-off time.
    payment[:requestedExecutionDate] = next_execution_date
    # Not every bank accepts a transfer without remittance information, but
    # some reject it when it is set at all -- so leave it out when empty.
    reference = invoice.number.to_s
    payment[:remittanceInformationUnstructured] = reference if reference.present?
    payment
  end

  def next_execution_date
    date = (@execution_date || Time.current).to_date
    date = date.next_day while date.saturday? || date.sunday?
    date.strftime('%Y-%m-%d')
  end

  def gateway_of(invoice)
    bank_account_of(invoice)&.bank_gateway
  end

  def payer_iban(invoice)
    bank_account_of(invoice)&.iban
  end

  def bank_account_of(invoice)
    invoice.supplier&.supplier_category&.bank_account
  end
end
