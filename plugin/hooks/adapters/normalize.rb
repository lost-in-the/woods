# frozen_string_literal: true

require 'json'

# Standalone stdlib fallback for hosts without jq; never loads the Woods bundle.
module WoodsHookEvent
  module_function

  def string?(value)
    value.is_a?(String) && !value.empty? && value.bytesize <= 4096 && !value.include?("\0") && value.valid_encoding?
  end

  def normalize(client, input)
    raise ArgumentError unless input.is_a?(Hash)

    root, events = client_event(client, input)
    validate_envelope(root, events)

    normalized = events.map { |event| normalize_event(event) }.uniq
    { 'version' => 1, 'root' => root,
      'events' => normalized.sort_by { |event| event.values_at('path', 'operation') } }
  end

  def validate_envelope(root, events)
    raise ArgumentError unless string?(root) && root.start_with?('/')
    raise ArgumentError unless events.is_a?(Array) && events.size.between?(1, 1000)
  end

  def client_event(client, input)
    case client
    when 'claude' then claude_event(input)
    when 'opencode'
      raise ArgumentError unless input['version'] == 1 && input['client'] == 'opencode'

      [input['root'], input['events']]
    else raise ArgumentError
    end
  end

  def claude_event(input)
    raise ArgumentError unless input['hook_event_name'] == 'PostToolUse' &&
                               %w[Write Edit MultiEdit].include?(input['tool_name']) &&
                               input['tool_input'].is_a?(Hash)

    [input['cwd'], [{ 'path' => input.fetch('tool_input').fetch('file_path'), 'operation' => 'update' }]]
  end

  def normalize_event(event)
    raise ArgumentError unless event.is_a?(Hash) && string?(event['path']) &&
                               %w[add update delete].include?(event['operation'])

    { 'path' => event['path'], 'operation' => event['operation'] }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    input = $stdin.binmode.read(1_048_577).force_encoding(Encoding::UTF_8)
    puts JSON.generate(WoodsHookEvent.normalize(ARGV.fetch(0), JSON.parse(input)))
  rescue JSON::ParserError, EncodingError, ArgumentError, KeyError, TypeError
    warn '[Woods hooks] Unsupported or malformed edit event; no refresh queued.'
    exit 1
  end
end
