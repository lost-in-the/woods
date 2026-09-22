# frozen_string_literal: true

require 'json'
require 'digest'
require 'woods/published_index'
require 'woods/source_inputs/status'
cid = ENV.fetch('PILOT_CASE')
item = JSON.parse(File.read("/evaluation/results/#{cid}-case.json"))
index_dir = Rails.root.join('tmp/woods')
packet = {}
Woods::PublishedIndex.open(index_dir) do |index|
  entries = index.units.select do |entry|
    item['identities'].any? do |identifier, _|
      identifier == entry['identifier']
    end || entry['identifier'] == 'BehavioralProfile'
  end
  units = entries.map { |entry| index.unit(entry['identifier'], type: entry['type']) }.compact
  wanted = units.map { |unit| unit['identifier'] }
  packet = {
    generation: index.generation_number,
    manifest: index.manifest,
    freshness: Woods::SourceInputs::Status.new(output_dir: index_dir, payload_dir: index.payload_dir,
                                               generation: index.generation_number, mode: 'deep').call,
    units: units,
    relationships: index.edges.select { |edge| wanted.include?(edge[:from]) || wanted.include?(edge[:to]) },
    runtime: { rails_version: Rails.version, ruby_version: RUBY_VERSION, database: ActiveRecord::Base.connection.adapter_name,
               active_job_adapter: Rails.application.config.active_job.queue_adapter,
               delivery_job_adapter: ReviewDeliveryJob.queue_adapter.class.name,
               delivery_job_enqueue_after_transaction_commit: ReviewDeliveryJob.enqueue_after_transaction_commit },
    source_files: ([item['path']] + item['support']).to_h { |path| [path, File.read(Rails.root.join(path))] },
    source_hashes: ([item['path']] + item['support']).to_h do |path|
      [path, Digest::SHA256.file(Rails.root.join(path)).hexdigest]
    end,
    checked_out_sha: `git rev-parse HEAD`.strip, working_tree: `git status --porcelain`.lines,
    index_checksum: index.external_dependency_checksum
  }
end
raise 'Index is not current' unless packet[:freshness][:state] == 'current' || packet[:freshness]['state'] == 'current'
raise 'Candidate worktree is dirty' unless packet[:working_tree].empty?
raise 'Candidate revision differs' unless packet[:checked_out_sha] == item.fetch('materialized_head', item['head'])

File.write("/evaluation/results/#{cid}-evidence.json", JSON.pretty_generate(packet))
result = { case_id: cid, family: item['family'] }
case item['family']
when 'callback'
  record = ReviewItem.create!(name: 'Initial')
  ReviewRename.call(record, '  Changed  ')
  record.reload
  result.merge!(actual: record.normalized_name, expected: 'changed',
                contract_holds: record.normalized_name == 'changed')
when 'authorization'
  client = ActionDispatch::Integration::Session.new(Rails.application)
  client.get('/review_reports/show')
  private_status = client.response.status
  client.get('/review_reports/preview')
  preview_status = client.response.status
  client.get('/review_reports/show', headers: { 'X-Review-Role' => 'reviewer' })

  authorized_status = client.response.status
  result.merge!(private_status: private_status, preview_status: preview_status, authorized_status: authorized_status,
                contract_holds: private_status == 403 && preview_status == 200 && authorized_status == 200)
when 'transaction'
  adapter = ReviewDeliveryJob.queue_adapter
  adapter.enqueued_jobs.clear
  ReviewDelivery.transaction do
    ReviewDelivery.create!(payload: 'rolled back')
    raise ActiveRecord::Rollback
  end
  after_rollback = adapter.enqueued_jobs.length
  adapter.enqueued_jobs.clear
  ReviewDelivery.create!(payload: 'committed')
  after_commit = adapter.enqueued_jobs.length
  result.merge!(queued_after_rollback: after_rollback, queued_after_commit: after_commit,
                contract_holds: after_rollback.zero? && after_commit == 1)
when 'schema'
  rejected = false
  begin
    ReviewRegistryEntry.insert_all!([{ external_key: 'same-key' }, { external_key: 'same-key' }])
  rescue ActiveRecord::RecordNotUnique
    rejected = true
  end
  result.merge!(duplicate_insert_rejected: rejected, contract_holds: rejected)
end
result[:expected_contract_holds] = !item['defect']
result[:oracle_matches_intended_case] = result[:contract_holds] == result[:expected_contract_holds]
File.write("/evaluation/results/#{cid}-oracle.json", JSON.pretty_generate(result))
puts JSON.generate(result)

raise 'Oracle does not match intended mechanism' unless result[:oracle_matches_intended_case]
