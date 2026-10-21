# frozen_string_literal: true

require 'json'
require_relative 'atomic_file'
require_relative 'generation'

module Woods
  # Durable operational state, separate from immutable generation payloads.
  # Pin updates and retention share a stable flock inode; the JSON file is
  # atomically replaced and is never itself used as the lock target.
  class GenerationPins
    FILENAME = 'generation_pins.json'
    LOCK_FILENAME = '.generation-pins.lock'

    def initialize(output_dir)
      @root = Pathname.new(output_dir.to_s)
    end

    # @return [Array<Integer>] sorted generation numbers, empty on older indexes
    # @raise [IOError] malformed state must never silently release retention pins
    def pins
      data = JSON.parse(AtomicFile.read(@root.join(FILENAME)))
      raise IOError, 'Generation pin state is malformed' unless valid_state?(data)

      data['generations'].uniq.sort
    rescue Errno::ENOENT
      []
    rescue JSON::ParserError, EncodingError
      raise IOError, 'Generation pin state is unreadable or malformed'
    end

    # @return [Boolean] true when a pin was added, false when already pinned
    def pin(number)
      number = generation_number(number)
      synchronize do |numbers|
        validate_payload!(number)
        next false if numbers.include?(number)

        write(numbers + [number])
        true
      end
    end

    # A pin whose payload was removed externally can still be released.
    # @return [Boolean] true when released, false when already unpinned
    def unpin(number)
      number = generation_number(number)
      synchronize do |numbers|
        unless numbers.include?(number)
          validate_payload!(number)
          next false
        end

        write(numbers - [number])
        true
      end
    end

    # All cooperating pruners hold this lock through deletion. A successful
    # pin therefore either precedes deletion or rejects an already-gone payload.
    # The sidecar stays in place after unlock to avoid splitting lock identity.
    def synchronize
      raise ArgumentError, 'Generation index directory does not exist' unless @root.directory?

      File.open(@root.join(LOCK_FILENAME), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield pins
      end
    end

    private

    def valid_state?(data)
      data.is_a?(Hash) && data['version'] == 1 && data['generations'].is_a?(Array) &&
        data['generations'].all? { |number| positive_integer?(number) }
    end

    def positive_integer?(number)
      number.is_a?(Integer) && number.positive?
    end

    def generation_number(number)
      return number if number.is_a?(Integer) && number.positive?
      return number.to_i if number.is_a?(String) && number.match?(/\A[1-9]\d*\z/)

      raise ArgumentError, 'Generation must be a positive integer number'
    end

    def validate_payload!(number)
      marker = Generation.new(output_dir: @root).current!
      raise ArgumentError, 'Generation is not a retained published payload' unless published_number?(marker, number)

      directory = @root.join("payloads/gen-#{number}")
      raise ArgumentError, 'Generation payload is missing or symlinked' unless retained_directory?(directory, number)

      %w[manifest.json dependency_graph.json].each do |name|
        raise ArgumentError, 'Generation payload is incomplete' unless valid_artifact?(directory.join(name))
      end
    rescue Generation::InvalidMarker, SystemCallError, JSON::ParserError, EncodingError
      raise ArgumentError, 'Generation payload is missing, unreadable or malformed'
    end

    def published_number?(marker, number)
      positive_integer?(marker.number) && marker.token.is_a?(String) && !marker.token.empty? &&
        marker.payload == "payloads/gen-#{marker.number}" && number <= marker.number
    end

    def retained_directory?(directory, number)
      directory.directory? && directory.realpath == @root.realpath.join("payloads/gen-#{number}") &&
        @root.join('payloads').realpath == @root.realpath.join('payloads')
    end

    def valid_artifact?(path)
      path.file? && !path.symlink? && JSON.parse(AtomicFile.read(path)).is_a?(Hash)
    end

    def write(numbers)
      AtomicFile.write(@root.join(FILENAME).to_s, JSON.generate('version' => 1, 'generations' => numbers.sort))
    end
  end
end
