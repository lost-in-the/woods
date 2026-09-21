# frozen_string_literal: true

require 'json'
require 'active_support/testing/time_helpers'

cid = ENV.fetch('INVESTIGATION_CASE')
item = JSON.parse(File.read('/evaluation/cases.json')).find { |row| row.fetch('id') == cid }
result = { case_id: cid, family: item.fetch('family') }

case item.fetch('family')
when 'invoice_rounding'
  samples = [
    { unit_price: '0.335', quantity: 1, lines: 3, expected: '1.01' },
    { unit_price: '-0.335', quantity: 1, lines: 3, expected: '-1.01' },
    { unit_price: '2.675', quantity: 2, lines: 2, expected: '10.70' }
  ].map do |sample|
    lines = Array.new(sample.fetch(:lines)) do
      { 'unit_price' => sample.fetch(:unit_price), 'quantity' => sample.fetch(:quantity) }
    end
    response = InvestigationInvoiceRequest.call(JSON.generate(lines: lines))
    sample.merge(actual: response.fetch(:total), currency: response.fetch(:currency),
                 matches: BigDecimal(response.fetch(:total)) == BigDecimal(sample.fetch(:expected)))
  end
  result.merge!(samples: samples, contract_holds: samples.all? { |sample| sample.fetch(:matches) })
when 'json_key_shape'
  supplied = InvestigationDigestRequest.call(JSON.generate(heading: 'Monthly field notes', window_days: 30)).reload
  defaults = InvestigationDigestRequest.call('{}').reload
  actual = [supplied, defaults].map { |digest| { heading: digest.heading, window_days: digest.window_days } }
  expected = [{ heading: 'Monthly field notes', window_days: 30 }, { heading: 'Daily activity', window_days: 7 }]
  result.merge!(persisted_records: actual, expected_records: expected, contract_holds: actual == expected)
when 'nested_reservation'
  sql = []
  listener = lambda do |_name, _start, _finish, _id, payload|
    statement = payload.fetch(:sql)
    sql << statement if statement.match?(/SAVEPOINT|ROLLBACK|TRANSACTION/i)
  end
  rejected_pool = InvestigationPool.create!(available: 3)
  accepted_pool = InvestigationPool.create!(available: 9)
  outcomes = nil
  ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
    outcomes = [InvestigationReservationBatch.call(rejected_pool, 5),
                InvestigationReservationBatch.call(accepted_pool, 4)]
  end
  balances = [rejected_pool.reload.available, accepted_pool.reload.available]
  reservations = [rejected_pool, accepted_pool].map { |pool| pool.investigation_reservations.pluck(:seats) }
  attempts = InvestigationAttempt.order(:id).pluck(:outcome)
  result.merge!(outcomes: outcomes, available_seats: balances, reservations: reservations,
                attempts: attempts, transaction_sql: sql,
                contract_holds: outcomes == %i[unavailable reserved] && balances == [3, 5] &&
                  reservations == [[], [4]] && attempts == %w[unavailable reserved])
when 'local_calendar_day'
  clock = Object.new.extend(ActiveSupport::Testing::TimeHelpers)
  samples = [Time.utc(2026, 1, 1, 2, 30), Time.utc(2026, 7, 1, 2, 30)].map do |instant|
    clock.travel_to(instant) do
      InvestigationEvent.delete_all
      InvestigationEvent.create!(label: 'Before clock', created_at: instant - 1.hour)
      InvestigationEvent.create!(label: 'After clock', created_at: instant + 12.hours)
      local_date = Time.zone.today
      beginning = Time.zone.local(local_date.year, local_date.month, local_date.day)
      tomorrow = local_date + 1
      ending = Time.zone.local(tomorrow.year, tomorrow.month, tomorrow.day)
      expected = InvestigationEvent.order(:created_at).select do |event|
        event.created_at >= beginning && event.created_at < ending
      end.map(&:label)
      actual = InvestigationActivityExport.call.map { |event| event.fetch(:label) }
      { instant: instant.iso8601, local_date: local_date.to_s, operating_system_date: Date.today.to_s,
        expected: expected, actual: actual, matches: actual == expected }
    end
  end
  result.merge!(time_zone: Time.zone.name, samples: samples,
                contract_holds: samples.all? { |sample| sample.fetch(:matches) })
end

result[:expected_contract_holds] = !item.fetch('defect')
result[:oracle_matches_intended_case] = result.fetch(:contract_holds) == result.fetch(:expected_contract_holds)
File.write("/evaluation/results/#{cid}-oracle.json", JSON.pretty_generate(result))
puts JSON.generate(result)
raise 'Oracle does not match intended mechanism' unless result.fetch(:oracle_matches_intended_case)
