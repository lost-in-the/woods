# frozen_string_literal: true

# Wrap an instance method for one example without rspec-mocks.
#
# `allow_any_instance_of(...).and_wrap_original` raised a FrozenError on
# Ruby 3.0 and 3.1 when the wrapped method took a frozen positional array
# alongside keyword arguments, so a spec that needs to observe or filter a
# real call goes through this instead. The wrapper is installed once per
# method as a prepended module and does nothing unless an example has
# activated it; it is process-wide rather than thread-local because the
# extractor calls some of these methods from worker threads.
module ExampleScopedWrap
  MUTEX = Mutex.new
  @active = {}
  @installed = {}

  class << self
    # @return [Proc, nil] the wrapper an example activated for +key+
    def active(key) = MUTEX.synchronize { @active[key] }

    # @param klass [Module]
    # @param method_name [Symbol]
    # @yieldparam original [Proc] calls the real method with the given args
    # @return [void]
    def activate(klass, method_name, &wrapper)
      key = [klass, method_name]
      MUTEX.synchronize do
        install(klass, method_name, key) unless @installed[key]
        @active[key] = wrapper
      end
    end

    def reset!
      MUTEX.synchronize { @active.clear }
    end

    private

    def install(klass, method_name, key)
      wrapping = Module.new do
        define_method(method_name) do |*args, **opts, &block|
          wrapper = ExampleScopedWrap.active(key)
          return super(*args, **opts, &block) unless wrapper

          wrapper.call(->(*inner, **inner_opts) { super(*inner, **inner_opts, &block) }, *args, **opts)
        end
      end
      klass.prepend(wrapping)
      @installed[key] = wrapping
    end
  end
end

RSpec.configure do |config|
  config.after { ExampleScopedWrap.reset! }
end
