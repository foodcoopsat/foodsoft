class BankGateway < ApplicationRecord
  has_many :bank_accounts, dependent: :nullify
  belongs_to :unattended_user, class_name: 'User', optional: true

  scope :with_unattended_support, -> { where.not(unattended_user: nil) }

  validates :name, :url, presence: true

  def connector
    BankGatewayConnector.new self
  end

  # Whether the given user may (re)start the interactive onboarding of this
  # gateway at the bank. That grants access to the account data of the whole
  # gateway, so it is limited to the users the gateway is configured for.
  def can_reconfigure?(user)
    unattended_user == user || user.role_admin?
  end
end
