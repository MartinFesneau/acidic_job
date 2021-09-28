# frozen_string_literal: true

require "active_record"
require "active_job"
require "minitest"
require "minitest/mock"
require "logger"
require "sqlite3"
require "database_cleaner/active_record"
require "sidekiq"
require "sidekiq/testing"

# DATABASE AND MODELS ----------------------------------------------------------
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "test/database.sqlite",
  flags: SQLite3::Constants::Open::READWRITE |
         SQLite3::Constants::Open::CREATE |
         SQLite3::Constants::Open::SHAREDCACHE
)

DatabaseCleaner.clean_with :truncation

GlobalID.app = :test

# rubocop:disable Metrics/BlockLength
ActiveRecord::Schema.define do
  create_table :acidic_job_keys, force: true do |t|
    t.string :idempotency_key, null: false
    t.string :job_name, null: false
    t.text :job_args, null: false
    t.datetime :last_run_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    t.datetime :locked_at, null: true
    t.string :recovery_point, null: false
    t.text :error_object
    t.timestamps

    t.index %i[idempotency_key job_name job_args], unique: true,
                                                   name: "idx_acidic_job_keys_on_idempotency_key_n_job_name_n_job_args"
  end

  create_table :staged_acidic_jobs, force: true do |t|
    t.string :adapter, null: false
    t.string :job_name, null: false
    t.text :job_args, null: true
  end

  create_table :audits, force: true do |t|
    t.references :auditable, polymorphic: true
    t.references :associated, polymorphic: true
    t.references :user, polymorphic: true
    t.string :username
    t.string :action
    t.text :audited_changes
    t.integer :version, default: 0
    t.string :comment
    t.string :remote_address
    t.string :request_uuid
    t.timestamps

    t.index %i[auditable_type auditable_id version]
    t.index %i[associated_type associated_id]
    t.index %i[user_id user_type]
    t.index :request_uuid
  end

  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :stripe_customer_id, null: false
    t.timestamps
  end

  create_table :rides, force: true do |t|
    t.integer :origin_lat
    t.integer :origin_lon
    t.integer :target_lat
    t.integer :target_lon
    t.string :stripe_charge_id
    t.references :user, foreign_key: true, on_delete: :restrict
    t.timestamps
  end
end
# rubocop:enable Metrics/BlockLength

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  include GlobalID::Identification
end

class Audit < ApplicationRecord
  belongs_to :auditable, polymorphic: true
  belongs_to :associated, polymorphic: true
  belongs_to :user, polymorphic: true
end

class User < ApplicationRecord
  validates :email, presence: true
  validates :stripe_customer_id, presence: true
end

class Ride < ApplicationRecord
  belongs_to :user
end

# SEEDS ------------------------------------------------------------------------

USERS = [
  ["user@example.com", "tok_visa"],
  ["user-bad-source@example.com", "tok_chargeCustomerFail"]
].freeze

USERS.each do |(email, stripe_source)|
  User.create!(email: email,
               stripe_customer_id: stripe_source)
end

# LOGGING ----------------------------------------------------------------------

ActiveRecord::Base.logger = Logger.new(IO::NULL) # Logger.new($stdout)
ActiveJob::Base.logger = Logger.new(IO::NULL) # Logger.new($stdout)

# MOCKS ------------------------------------------------------------------------

module Stripe
  class CardError < StandardError; end

  class StripeError < StandardError; end

  class Charge
    extend AcidicJob::Deferrable::Behavior

    def self.create(params, _args)
      raise CardError, "Your card was declined." if params[:customer] == "tok_chargeCustomerFail"

      charge_struct = Struct.new(:id)
      charge_struct.new(123)
    end
  end
end

# TEST JOB ------------------------------------------------------------------------

class SendRideReceiptJob
  include Sidekiq::Worker
  include AcidicJob

  def perform(amount:, currency:, user_id:)
    { amount: amount, currency: currency, user_id: user_id }
  end
end

class ChargeAttemptJob < ActiveJob::Base
  def perform
    Stripe::Charge.create({
                                  amount: 20_00,
                                  currency: "usd",
                                  customer: user.stripe_customer_id,
                                  description: "Charge for ride #{ride.id}"
                                }, {
                                  # Pass through our own unique ID rather than the value
                                  # transmitted to us so that we can guarantee uniqueness to Stripe
                                  # across all Rocket Rides accounts.
                                  idempotency_key: "rocket-rides-atomic-#{key.id}"
                                })
    # if there is some sort of failure here (like server downtime), what happens?
    ride.update_column(:stripe_charge_id, charge.id)
  rescue Stripe::CardError
    # Short circuits execution by sending execution right to 'finished'.
    # So, ends the job "successfully"
    Response.new
  end
end

class RideCreateJob < ActiveJob::Base
  self.log_arguments = false

  include AcidicJob

  class SimulatedTestingFailure < StandardError; end

  def perform(user, ride_params)
    idempotently with: { user: user, params: ride_params, ride: nil } do
      step :create_ride_and_audit_record
      step :create_stripe_charge
      step :send_receipt
    end
  end

  private

  # rubocop:disable Metrics/MethodLength
  def create_ride_and_audit_record
    @ride = Ride.create!(
      origin_lat: params["origin_lat"],
      origin_lon: params["origin_lon"],
      target_lat: params["target_lat"],
      target_lon: params["target_lon"],
      stripe_charge_id: nil, # no charge created yet
      user: user
    )

    # in the same transaction insert an audit record for what happened
    Audit.create!(
      action: :AUDIT_RIDE_CREATED,
      auditable: ride,
      user: user,
      audited_changes: params
    )
  end
  # rubocop:enable Metrics/MethodLength

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  def create_stripe_charge
    # retrieve a ride record if necessary (i.e. we're recovering)
    if ride.nil?
      @ride = Ride.find_by!(
        origin_lat: params["origin_lat"],
        origin_lon: params["origin_lon"],
        target_lat: params["target_lat"],
        target_lon: params["target_lon"]
      )
    end

    raise SimulatedTestingFailure if defined?(raise_error)

    begin
      charge = Stripe::Charge.create({
                                       amount: 20_00,
                                       currency: "usd",
                                       customer: user.stripe_customer_id,
                                       description: "Charge for ride #{ride.id}"
                                     }, {
                                       # Pass through our own unique ID rather than the value
                                       # transmitted to us so that we can guarantee uniqueness to Stripe
                                       # across all Rocket Rides accounts.
                                       idempotency_key: "rocket-rides-atomic-#{key.id}"
                                     })
    rescue Stripe::CardError
      # Short circuits execution by sending execution right to 'finished'.
      # So, ends the job "successfully"
      Response.new
    else
      # if there is some sort of failure here (like server downtime), what happens?
      ride.update_column(:stripe_charge_id, charge.id)
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

  def send_receipt
    # Send a receipt asynchronously by adding an entry to the staged_jobs
    # table. By funneling the job through Postgres, we make this
    # operation transaction-safe.
    SendRideReceiptJob.perform_transactionally(
      amount: 20_00,
      currency: "usd",
      user_id: user.id
    )
  end
end
