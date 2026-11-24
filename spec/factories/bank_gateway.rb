require 'factory_bot'

FactoryBot.define do
  factory :bank_gateway do
    name { Faker::Bank.name }
    url { 'https://bank-gateway.example.org/' }
  end
end
