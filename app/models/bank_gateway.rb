class BankGateway < ApplicationRecord
  has_many :bank_accounts, dependent: :nullify
  belongs_to :unattended_user, class_name: 'User', optional: true

  scope :with_unattended_support, -> { where.not(unattended_user: nil) }

  validates_presence_of :name, :url

  def can_reconfigure?(user)
    return true if unattended_user == user
    user.role_admin?
  end

  def connector
    BankGatewayConnector.new self
  end
end
