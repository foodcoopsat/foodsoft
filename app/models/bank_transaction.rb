class BankTransaction < ApplicationRecord

  # @!attribute external_id
  #   @return [String] Unique Identifier of the transaction within the bank account.
  # @!attribute date
  #   @return [Date] Date of the transaction.
  # @!attribute amount
  #   @return [Number] Amount credited.
  # @!attribute iban
  #   @return [String] Internation Bank Account Number of the sending/receiving account.
  # @!attribute reference
  #   @return [String] 140 character long reference field as defined by SEPA.
  # @!attribute text
  #   @return [String] Short description of the transaction.
  # @!attribute receipt
  #   @return [String] Optional additional more detailed description of the transaction.
  # @!attribute image
  #   @return [Binary] Optional PNG image for e.g. scan of paper receipt.

  belongs_to :bank_account
  belongs_to :financial_link
  belongs_to :supplier, foreign_key: 'iban', primary_key: 'iban'
  belongs_to :user, foreign_key: 'iban', primary_key: 'iban'

  validates_presence_of :date, :amount, :bank_account_id
  validates_numericality_of :amount

  scope :without_financial_link, -> { where(financial_link: nil) }

  # Replace numeric seperator with database format
  localize_input_of :amount

  def image_url
    'data:image/png;base64,' + Base64.encode64(self.image)
  end

  def assign_to_invoice
    return false unless supplier

    content = text
    content += "\n" + reference if reference.present?
    invoices = supplier.invoices.unpaid.select {|i| content.include? i.number}
    invoices_sum = invoices.inject(0) {|sum,i| sum + i.amount }
    return false if amount != -invoices_sum

    ActiveRecord::Base.transaction do
      link = FinancialLink.new
      invoices.each {|i| i.update_attributes financial_link: link, paid_on: date}
      update_attribute :financial_link, link
    end

    return true
  end

  def assign_to_ordergroup
    m = /FS(?<group>\d+)(\.(?<user>\d+))?(?<parts>([A-Za-z]+\d+(\.\d+)?)+)/.match(reference)
    return assign_to_ordergroup_use_extended unless m

    h = Hash.new
    sum = 0
    m[:parts].scan(/([A-Za-z]+)(\d+(\.\d+)?)/) do |category, value|
      value = value.to_f
      sum += value
      value += h[category] if h[category]
      h[category] = value
    end

    return false if sum != amount
    group = Ordergroup.find_by_id(m[:group])
    return false unless group
    usr = m[:user] ? User.find_by_id(m[:user]) : group.users.first
    return false unless usr

    ActiveRecord::Base.transaction do
      note = "ID=#{id} (#{amount})"
      link = FinancialLink.new

      h.each do |short, value|
        group.add_financial_transaction! value, note, usr, FinancialTransactionType.find_by_name_short(short), link if value > 0
      end

      update_attribute :financial_link, link
    end

    return true
  end

  def assign_to_ordergroup_use_extended
    return false unless FoodsoftConfig[:use_extended]
    return false unless user
    ordergroup = user.ordergroup
    return false unless ordergroup

    m = /^\d+$/.match(reference)
    return false unless m

    amount_credit = 0
    amount_deposit = 0
    amount_membership = 0

    all_2 = true
    found_3 = false
    ref = reference.to_i.to_s

    ref.each_char { |c|
      all_2 = false if c != '2'
      case c
      when '1'
        if ref.length == 1
          amount_deposit = amount
        else
          amount_deposit += 30
        end
      when '2'
        if ref.length == 1
          amount_membership = amount
        else
          amount_membership += 10
        end
      when '3'
        found_3 = true
      end
    }

    amount_membership = amount if all_2
    amount_credit = amount - amount_deposit - amount_membership if found_3
    return false if amount != amount_credit + amount_membership + amount_deposit

    ActiveRecord::Base.transaction do
      note = "ID=#{id} (EUR #{amount})"
      link = FinancialLink.new
      ordergroup.add_financial_transaction! amount_deposit, note, user, FinancialTransactionType.find(1), link if amount_deposit > 0
      ordergroup.add_financial_transaction! amount_membership, note, user, FinancialTransactionType.find(2), link if amount_membership > 0
      ordergroup.add_financial_transaction! amount_credit, note, user, FinancialTransactionType.find(3), link if amount_credit > 0
      update_attribute :financial_link, link
    end

    return true
  end
end
