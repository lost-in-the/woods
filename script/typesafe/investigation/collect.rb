# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'woods/published_index'
require 'woods/source_inputs/status'

def captured_runtime
  {
    rails_version: Rails.version,
    ruby_version: RUBY_VERSION,
    database: ActiveRecord::Base.connection.adapter_name,
    active_job_adapter: Rails.application.config.active_job.queue_adapter,
    time_zone: Time.zone.name,
    configured_time_zone: Rails.application.config.time_zone,
    process_time_zone: ENV.fetch('TZ')
  }
end

def git_output(*arguments)
  stdout, stderr, status = Open3.capture3('git', *arguments)
  raise "Git command failed: #{stderr}" unless status.success?

  stdout
end

cid = ENV.fetch('INVESTIGATION_CASE')
item = JSON.parse(File.read('/evaluation/cases.json')).find { |row| row.fetch('id') == cid }
index_dir = Rails.root.join('tmp/woods')
packet = nil
Woods::PublishedIndex.open(index_dir) do |index|
  entries = index.units.select do |entry|
    item.fetch('identities').any? do |identifier, _|
      identifier == entry['identifier']
    end
  end
  units = entries.map { |entry| index.unit(entry['identifier'], type: entry['type']) }.compact
  wanted = units.map { |unit| unit['identifier'] }
  files = (item.fetch('changed_paths') + item.fetch('support')).uniq
  packet = {
    generation: index.generation_number,
    manifest: index.manifest,
    freshness: Woods::SourceInputs::Status.new(output_dir: index_dir, payload_dir: index.payload_dir,
                                               generation: index.generation_number, mode: 'deep').call,
    units: units,
    relationships: index.edges.select { |edge| wanted.include?(edge[:from]) || wanted.include?(edge[:to]) },
    runtime: captured_runtime,
    source_files: files.to_h { |path| [path, File.read(Rails.root.join(path))] },
    source_hashes: files.to_h { |path| [path, Digest::SHA256.file(Rails.root.join(path)).hexdigest] },
    source_metadata: files.to_h do |path|
      [path, { physical_path: path, line_start: 1, line_end: File.foreach(Rails.root.join(path)).count }]
    end,
    checked_out_sha: git_output('rev-parse', 'HEAD').strip,
    working_tree: git_output('status', '--porcelain').lines,
    index_checksum: index.external_dependency_checksum
  }
end
raise 'Index is not current' unless packet[:freshness][:state] == 'current' || packet[:freshness]['state'] == 'current'
raise 'Candidate revision differs' unless packet[:checked_out_sha] == item.fetch('head')
raise 'Candidate worktree is dirty' unless packet[:working_tree].empty?

item.fetch('cards').each do |card|
  raise 'Card source changed' unless packet[:source_files].fetch(card.fetch('path')) == card.fetch('source')
  raise 'Card hash changed' unless packet[:source_hashes].fetch(card.fetch('path')) == card.fetch('sha256')
end
File.write("/evaluation/results/#{cid}-evidence.json", JSON.pretty_generate(packet))
