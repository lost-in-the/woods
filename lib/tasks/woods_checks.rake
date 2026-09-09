# frozen_string_literal: true

# lib/tasks/woods_checks.rake
#
# Deterministic checks over a published index (#280). None of these boot
# Rails: they read retained payload generations through Woods::PublishedIndex.
#
# Usage:
#   bundle exec rake woods:check:moved_messages          # previous vs published generation
#   bundle exec rake "woods:check:moved_messages[41,42]" # explicit generations
#   WOODS_CHECK_STRICT=1 ...                             # exit 1 on findings (still heuristic; see below)

require 'json'

namespace :woods do
  namespace :check do
    desc 'Candidate moves into a unit without mapped tests, between two retained generations ' \
         '(heuristic: name+kind match, not a proven coverage loss; see docs/PUBLISHED_INDEX.md)'
    task :moved_messages, %i[from to] do |_task, args|
      Woods::CheckTasks.run_moved_messages(from: args[:from], to: args[:to])
    end
  end
end

module Woods
  # Bodies of the `woods:check:*` tasks. A module, not bare defs, so nothing
  # lands on Object in the host application.
  module CheckTasks
    module_function

    # @param from [String, Integer, nil] older generation; defaults to the one before `to`
    # @param to [String, Integer, nil] newer generation; defaults to the published one
    # @return [void]
    def run_moved_messages(from: nil, to: nil)
      require 'woods/published_index'
      require 'woods/checks/moved_messages'
      require 'woods/checks/generation_resolution'

      index_dir = check_index_dir
      available = Woods::PublishedIndex.available_generations(index_dir)
      resolved = Woods::Checks::GenerationResolution.call(available, from: from, to: to)
      abort_for_insufficient_generations(index_dir, available) unless resolved

      from_number, to_number = resolved
      puts "Comparing generation #{from_number} to #{to_number} under #{index_dir}"

      findings = compare_generations(index_dir, from_number, to_number)

      print_moved_messages(findings)
      exit 1 if findings.any? && ENV['WOODS_CHECK_STRICT'] == '1'
    rescue Woods::PublishedIndex::CorruptPointerError => e
      # Let it propagate (a corrupt install is not "0 findings"), but name the
      # task first: a bare CorruptPointerError backtrace from deep inside
      # PublishedIndex gives no hint this came from a rake task at all.
      warn "woods:check:moved_messages: #{e.message}"
      raise
    end

    # WOODS_OUTPUT, or tmp/woods beside the loaded Rakefile (the same
    # resolution woods:watch_status uses; no Rails boot).
    #
    # @return [String]
    def check_index_dir
      ENV.fetch('WOODS_OUTPUT') do
        root = respond_to?(:woods_task_root, true) ? woods_task_root : Rake.application.original_dir
        File.join(root, 'tmp/woods')
      end
    end

    # @param index_dir [String]
    # @param from_number [Integer]
    # @param to_number [Integer]
    # @return [Array<Woods::Checks::MovedMessages::Finding>]
    def compare_generations(index_dir, from_number, to_number)
      Woods::PublishedIndex.open(index_dir, generation: from_number) do |before|
        Woods::PublishedIndex.open(index_dir, generation: to_number) do |after|
          Woods::Checks::MovedMessages.new(before: before, after: after).run
        end
      end
    end

    # @param index_dir [String]
    # @param available [Array<Integer>]
    # @return [void]
    def abort_for_insufficient_generations(index_dir, available)
      warn "ERROR: need two retained generations under #{index_dir}; found #{available.inspect}."
      warn 'Run two extractions, or raise WOODS_PAYLOAD_RETENTION, or pass [from,to] explicitly.'
      exit 1
    end

    # @param findings [Array<Woods::Checks::MovedMessages::Finding>]
    # @return [void]
    def print_moved_messages(findings)
      if findings.empty?
        puts 'No candidate moves into a unit without mapped tests.'
        return
      end

      puts "#{findings.size} candidate move(s) into a unit without mapped tests:"
      findings.each do |finding|
        puts "  #{finding.method} (#{finding.kind}): #{finding.from_unit} -> #{finding.to_unit} " \
             "(covered before: #{finding.covered_before}, covered after: #{finding.covered_after})"
      end
      puts JSON.pretty_generate(findings.map(&:to_h)) if ENV['WOODS_CHECK_JSON'] == '1'
    end
  end
end
