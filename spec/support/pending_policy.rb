# frozen_string_literal: true

# CI may omit explicitly opt-in lanes, but examples that actually run must not
# silently become pending. Match the specific example AND its capability reason;
# copying a skip message into another test must not bypass this gate.
module PendingPolicy
  ROOT = File.expand_path('../..', __dir__)
  ENTRIES = [
    *['overestimates by a bounded amount against cl100k_base',
      'never underestimates by more than 5%'].map do |description|
      ['spec/token_estimation_benchmark_spec.rb', "Token estimation accuracy with tiktoken_ruby #{description}",
       'tiktoken_ruby not installed — run: gem install tiktoken_ruby', lambda {
         begin
           require 'tiktoken_ruby'
           false
         rescue LoadError
           true
         end
       }]
    end,
    *['compiles the user pattern with a per-match time limit',
      'compiles the escaped fallback with the same per-match time limit'].map do |description|
      ['spec/mcp/index_reader_spec.rb', "Woods::MCP::IndexReader bounded user search regex #{description}",
       'per-pattern Regexp timeouts need Ruby 3.2+', -> { Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.2') }]
    end,
    ['spec/mcp/tasks/store_spec.rb',
     'Woods::MCP::Tasks::Store producer identity reads the actual current Linux process identity ' \
     'when procfs is available',
     'procfs is unavailable on this platform', -> { !File.readable?('/proc/sys/kernel/random/boot_id') }],
    ['spec/operator/pipeline_guard_spec.rb',
     'Woods::Operator::PipelineGuard#allow? fails closed (denies) when the state file is unreadable',
     'requires non-root: chmod 0o000 does not stop root from reading', -> { Process.uid.zero? }],
    ['spec/operator/pipeline_guard_spec.rb',
     'Woods::Operator::PipelineGuard#state_status reports :permission_denied for a state file ' \
     'this process cannot read, distinct from :corrupt',
     'requires non-root: chmod 0o000 does not stop root from reading', -> { Process.uid.zero? }],
    ['spec/mcp/tasks/pipeline_tasks_spec.rb',
     'pipeline tools and the Tasks extension when opted-in task storage is read-only ' \
     'fails closed without starting untrackable work',
     'requires non-root: chmod 0o555 does not stop root from writing', -> { Process.uid.zero? }]
  ].freeze

  def self.allowed?(example)
    ENTRIES.any? do |file, description, reason, unavailable|
      File.expand_path(example.metadata.fetch(:file_path)) == File.join(ROOT, file) &&
        example.full_description == description &&
        example.execution_result.pending_message == reason && unavailable.call
    end
  end
end

RSpec.configure do |config|
  config.after(:suite) do
    next unless ENV['CI']

    unexpected = RSpec.world.all_examples.select do |example|
      example.execution_result.status == :pending && !PendingPolicy.allowed?(example)
    end
    next if unexpected.empty?

    details = unexpected.map do |example|
      "#{example.location}: #{example.full_description} (#{example.execution_result.pending_message})"
    end
    raise "Unexpected pending examples in CI:\n#{details.join("\n")}"
  end
end
