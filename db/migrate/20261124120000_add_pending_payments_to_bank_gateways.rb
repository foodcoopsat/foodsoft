class AddPendingPaymentsToBankGateways < ActiveRecord::Migration[7.2]
  def change
    add_column :bank_gateways, :pending_payments, :text
  end
end
