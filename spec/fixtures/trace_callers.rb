# frozen_string_literal: true

# Ordinary Ruby method definitions are intentional: these regressions exercise
# real :call/:return events, rather than recording handcrafted trace hashes.
module TraceCallerFixture
  class Caller
    def invoke(callee)
      callee.run
    end

    def recover(callee)
      unwind(callee)
    rescue RuntimeError
      callee.run
    end

    def unwind(callee)
      callee.explode
    end

    def pause_and_invoke(callee)
      Fiber.yield
      callee.run
    end

    def wait_and_invoke(callee, started, proceed)
      started << true
      proceed.pop
      callee.run
    end

    def catch_throw(callee)
      catch(:fixture_exit) { callee.throw_exit }
      callee.run
    end

    def record_inside(recorder, callee)
      recorder.record { callee.run }
    end
  end

  class OtherCaller
    def invoke(callee)
      callee.run
    end
  end

  class Callee
    def run
      'result'
    end

    def recurse(depth)
      return run if depth.zero?

      recurse(depth - 1)
    end

    def throw_exit
      throw :fixture_exit
    end

    def explode
      raise 'fixture failure'
    end
  end
end
