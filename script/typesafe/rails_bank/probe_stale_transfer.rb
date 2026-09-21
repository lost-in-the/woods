# frozen_string_literal: true

# Run through Rails runner in a disposable copy of the synthetic transfer app.
# This exercises an admissible read/commit ordering, without starting threads or
# claiming the caller in an arbitrary application permits stale model inputs.
require 'digest'
require 'json'

class StaleTransferProbe
  def initialize(kind, fresh:)
    @kind = kind
    @fresh = fresh
    @wallets, @calls, @expected = layout
  end

  def run
    before = balances
    # Both sets of objects are loaded before either transfer commits.
    loaded = @calls.map do |source, destination|
      [ReviewWallet.find(source.id), ReviewWallet.find(destination.id)]
    end
    steps = loaded.map { |source, destination| transfer(source, destination) }
    after = balances
    { loading: @fresh ? 'fresh find before each transfer' : 'both snapshots read before first transfer',
      before: before, steps: steps, after: after, expected: @expected,
      total_before: before.values.sum, total_after: after.values.sum,
      expected_balances_hold: after == @expected }
  end

  private

  def wallet(balance)
    ReviewWallet.create!(balance: balance, limit: 1000)
  end

  def layout
    return shared_destination if @kind == :shared_destination

    shared_source
  end

  def shared_destination
    sender_a = wallet(100)
    sender_b = wallet(100)
    recipient = wallet(0)
    [{ sender_a: sender_a, sender_b: sender_b, recipient: recipient },
     [[sender_a, recipient], [sender_b, recipient]],
     { sender_a: 90, sender_b: 90, recipient: 20 }]
  end

  def shared_source
    sender = wallet(100)
    recipient_a = wallet(0)
    recipient_b = wallet(0)
    [{ sender: sender, recipient_a: recipient_a, recipient_b: recipient_b },
     [[sender, recipient_a], [sender, recipient_b]],
     { sender: 80, recipient_a: 10, recipient_b: 10 }]
  end

  def balances
    @wallets.transform_values { |record| ReviewWallet.find(record.id).balance }
  end

  def transfer(source, destination)
    source = ReviewWallet.find(source.id) if @fresh
    destination = ReviewWallet.find(destination.id) if @fresh
    loaded_before = { source: source.balance, destination: destination.balance }
    ReviewCreditTransfer.call(source, destination, 10)
    { loaded_before: loaded_before, persisted_after: balances }
  end
end

sql = []
observer = lambda do |*arguments|
  statement = arguments.last[:sql]
  sql << statement if statement.include?('review_wallets')
end
results = nil
ActiveRecord::Base.uncached do
  ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') do
    results = %i[shared_destination shared_source].to_h do |kind|
      stale = StaleTransferProbe.new(kind, fresh: false).run
      fresh = StaleTransferProbe.new(kind, fresh: true).run
      raise 'Stale interleaving did not reproduce the additional mechanism' if stale[:expected_balances_hold]
      raise 'Fresh-load comparison failed' unless fresh[:expected_balances_hold]
      raise 'Fresh-load comparison changed the credit total' unless fresh[:total_before] == fresh[:total_after]

      [kind, { stale: stale, fresh: fresh }]
    end
  end
end

files = %w[app/services/review_credit_transfer.rb app/models/review_wallet.rb db/schema.rb]
receipt = {
  classification: 'Conditional additional mechanism; original atomicity label is unchanged',
  premise: 'Separate transfers receive snapshots of an overlapping wallet read before the first transfer commits',
  method: 'Deterministic admissible read/commit interleaving; not simultaneous-thread testing',
  runtime: { rails: Rails.version, ruby: RUBY_VERSION, adapter: ActiveRecord::Base.connection.adapter_name },
  candidate_sha: `git rev-parse HEAD`.strip,
  working_tree: `git status --porcelain`.lines,
  model_columns: ReviewWallet.column_names,
  optimistic_locking_disabled: !ReviewWallet.locking_enabled?,
  configured_locking_column: ReviewWallet.locking_column,
  source_files: files.to_h { |path| [path, Digest::SHA256.file(Rails.root.join(path)).hexdigest] },
  scenarios: results,
  observed_sql: sql
}
puts JSON.pretty_generate(receipt)
