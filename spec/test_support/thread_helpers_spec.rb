# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe ThreadHelpers do
  it 'returns a received signal without waiting for the producer to finish' do
    queue = Queue.new
    queue << :ready

    expect(wait_for_thread_signal(queue, producer: Thread.current)).to eq(:ready)
  end

  it 'reports a blocked producer status and backtrace without joining it' do
    release = Queue.new
    producer = Thread.new { release.pop }
    poll_until { producer.status == 'sleep' }

    expect { wait_for_thread_signal(Queue.new, timeout: 0.01, later: producer) }
      .to raise_error(Timeout::Error, /later: status="sleep".*thread_helpers_spec/m)
    expect(producer).to be_alive
  ensure
    release << true
    producer&.join(1)
  end

  it 'reports a completed dispatch response when no signal was sent' do
    producer = Thread.new { { 'error' => { 'message' => 'dispatch rejected' } } }
    producer.join

    expect { wait_for_thread_signal(Queue.new, timeout: 0.01, later: producer) }
      .to raise_error(Timeout::Error, /later: status=false.*dispatch rejected/m)
  end

  it 'reports an exception raised before the producer could signal' do
    producer = Thread.new do
      Thread.current.report_on_exception = false
      raise KeyError, 'result missing'
    end
    begin
      producer.join
    rescue KeyError
      nil
    end

    expect { wait_for_thread_signal(Queue.new, timeout: 0.01, later: producer) }
      .to raise_error(Timeout::Error, /later: status=nil.*KeyError: result missing/m)
  end
end
