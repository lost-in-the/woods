# frozen_string_literal: true

require 'json'

module Woods
  # Compact JSON for the artifacts an extraction writes, byte for byte what
  # `JSON.generate` produces and several times faster inside a Rails process.
  #
  # Extraction data is full of Symbols (`type: :model`, `via: :belongs_to`).
  # `JSON.generate` hands every value that is not a JSON type to its
  # `to_json`, a Ruby method call per Symbol, which ActiveSupport also
  # wraps. A `JSON::Coder` writes the JSON types natively and calls one block
  # for the rest, so a Symbol costs its name and nothing else. On a
  # 10,000-unit dependency graph inside Rails that is 0.03 s against 0.17 s.
  #
  # Anything the coder refuses is given to `JSON.generate`, so a value this
  # cannot write is written, or refused, exactly as before.
  module CompactJson
    # A Symbol is its name. Any other object is written as `JSON.generate`
    # writes it: by its own `to_json` as a value, by `to_s` as an object key.
    CODER = JSON::Coder.new do |object, key|
      if object.is_a?(Symbol)
        object.name
      elsif key
        object.to_s
      else
        JSON::Fragment.new(object.to_json(JSON::State.new))
      end
    end
    private_constant :CODER

    module_function

    # @param data [Object] JSON-serializable data
    # @return [String] the bytes `JSON.generate(data)` returns
    # @raise [JSON::GeneratorError] when `JSON.generate` raises it
    def generate(data)
      CODER.dump(data)
    rescue JSON::GeneratorError, ArgumentError, TypeError
      JSON.generate(data)
    end
  end
end
