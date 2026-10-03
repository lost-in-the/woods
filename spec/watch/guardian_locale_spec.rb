# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'rbconfig'
require 'timeout'
require 'tmpdir'

# The guardian runs as `ruby --disable-gems guardian.rb` before Bundler or
# Rails, so nothing has set Encoding.default_external: under LC_ALL=C its
# config pipe reads US-ASCII. The config carries the application's root and
# whole child environment, so one non-ASCII value must not stop the launch.
RSpec.describe 'Woods::Watch::Guardian under a POSIX locale' do
  let(:guardian) { File.expand_path('../../lib/woods/watch/guardian.rb', __dir__) }

  def read_events(reader, until_event:)
    records = []
    buffer = +''
    Timeout.timeout(10) do
      until records.any? { |record| record['event'] == until_event }
        chunk = reader.readpartial(4096)
        buffer << chunk
        while (newline = buffer.index("\n"))
          records << JSON.parse(buffer.slice!(0..newline))
        end
      end
    end
    records
  rescue EOFError
    records
  end

  it 'launches the child when the config holds multibyte paths and environment values' do
    Dir.mktmpdir('ledger-café') do |root|
      config_reader, config_writer = IO.pipe
      parent_reader, parent_writer = IO.pipe
      events_reader, events_writer = IO.pipe
      config = { owner_pid: Process.pid, root: root, env: { 'LEDGER_LABEL' => 'Ledger — café' },
                 command: [RbConfig.ruby, '-e', 'exit 0'], shutdown_timeout: 1,
                 launcher: 'launcher', attempt: 'attempt' }
      config_writer.write(JSON.generate(config))
      config_writer.close

      pid = Process.spawn({ 'LC_ALL' => 'C', 'LANG' => 'C', 'RUBYOPT' => nil, 'RUBYLIB' => nil },
                          RbConfig.ruby, '--disable-gems', guardian,
                          3 => events_writer, 4 => parent_reader, 5 => config_reader,
                          in: File::NULL, err: File::NULL, close_others: true)
      [config_reader, parent_reader, events_writer].each(&:close)
      started = read_events(events_reader, until_event: 'spawned')
      begin
        parent_writer.write('S')
      rescue Errno::EPIPE
        nil # the guardian already exited; the event assertions below say why
      end
      finished = read_events(events_reader, until_event: 'exit')
      parent_writer.close
      _, status = Process.wait2(pid)

      expect((started + finished).map { |record| record['event'] }).to eq(%w[hello spawned exit])
      expect(finished.last['code']).to eq(0)
      expect(status.exitstatus).to eq(0)
    end
  end
end
