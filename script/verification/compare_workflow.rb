# frozen_string_literal: true

# Same resident workload with and without the workflow wrapper. The raw arm
# validates the same report, so a cheaper false-positive baseline cannot win.
require_relative 'resident_journey'
require 'rails'
require 'woods'
require 'English'
Signal.trap('TERM') { raise Interrupt }

root = File.realpath(ARGV.fetch(0))
raise 'Wrong candidate bundle' unless File.realpath(Gem.loaded_specs.fetch('woods').full_gem_path) == root

repetitions = Integer(ARGV.fetch(1, '5'))
raise ArgumentError, 'Use at least five paired repetitions' if repetitions < 5

output = Dir.mktmpdir('workflow-comparison-', File.join(root, 'tmp'))
identity_reader = WoodsVerification::ResidentJourney.allocate
identity_reader.instance_variable_set(:@root, root)
identity = identity_reader.send(:identity)
report = { status: 'incomplete', ruby: RUBY_DESCRIPTION, rails: Rails.version,
           workload: 'identical resident helper edit/restore with independent cold-full controls',
           baseline: 'raw fixture plus the same report assertions', treatment: 'workflow wrapper around that fixture',
           repetitions: repetitions, candidate: identity, samples: [],
           protocol: 'alternating paired order; correctness mandatory; cost descriptive, no speedup target',
           limits: ['Local synthetic workload, not development throughput or client acceptance.',
                    'Wrapper adds preflight and evidence; raw fixture already has behavioral assertions.',
                    'RSS uses getrusage maximum; it is not simultaneous whole-tree memory.'] }
File.write(File.join(output, 'comparison.json'), JSON.pretty_generate(report))
at_exit do
  if report[:status] != 'complete'
    report[:status] = $ERROR_INFO.is_a?(Interrupt) ? 'interrupted' : 'failed_or_incomplete'
    report[:error] = "#{$ERROR_INFO.class}: #{$ERROR_INFO.message}" if $ERROR_INFO
  end
  begin
    report[:ending_candidate] = identity_reader.send(:identity)
    report[:provenance_valid] = report[:ending_candidate] == identity
    report[:status] = 'invalidated' unless report[:provenance_valid]
  rescue StandardError => e
    report[:status] = 'invalidated'
    report[:provenance_error] = "#{e.class}: #{e.message}"
  end
  File.write(File.join(output, 'comparison.json'), JSON.pretty_generate(report))
  puts "Comparison artifact: #{output}"
  exit 1 if $ERROR_INFO.nil? && report[:status] != 'complete'
end
# rubocop:disable-next Metrics/BlockLength -- keep the paired protocol, owned process cleanup and per-sample record together.
repetitions.times do |repetition|
  order = repetition.even? ? %w[raw wrapped] : %w[wrapped raw]
  order.each do |arm|
    raise 'Candidate or verifier changed' unless identity_reader.send(:identity) == identity

    prefix = File.join(output, "#{repetition + 1}-#{arm}")
    metrics = "#{prefix}.metrics.json"
    stdout_path = "#{prefix}.stdout"
    stderr_path = "#{prefix}.stderr"
    load_average = File.read('/proc/loadavg').split.take(3).map(&:to_f)
    Dir.mktmpdir('woods-paired-') do |fixture_root|
      command = if arm == 'raw'
                  [RbConfig.ruby, '-Ilib', WoodsVerification::ResidentJourney::RESIDENT_FIXTURE,
                   fixture_root, 'resident', File.join(fixture_root, 'tmp/index')]
                else
                  [RbConfig.ruby, File.join(WoodsVerification::ResidentJourney::VERIFIER_ROOT,
                                            'script/verify-resident-journey'), root]
                end
      timing = <<~PYTHON
        import json, resource, subprocess, sys, time
        assert sys.platform.startswith("linux"), "RSS units are defined here for Linux only"
        started = time.monotonic()
        completed = subprocess.run(sys.argv[2:])
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        with open(sys.argv[1], "w") as output:
            json.dump({"wall_s": time.monotonic()-started, "user_s": usage.ru_utime,
                       "system_s": usage.ru_stime, "max_rss_kib": usage.ru_maxrss}, output)
        sys.exit(completed.returncode)
      PYTHON
      time = ['python3', '-c', timing, metrics]
      pid = Process.spawn({ 'BUNDLE_FROZEN' => 'true' }, *time, *command,
                          chdir: root, out: stdout_path, err: stderr_path, pgroup: true)
      begin
        _, status = Timeout.timeout(240) { Process.wait2(pid) }
      ensure
        unless status
          begin
            Process.kill('KILL', -pid)
          rescue Errno::ESRCH
            # Already exited; still reap below.
          end
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            # Already reaped.
          end
        end
      end
      raise "#{arm} failed; see #{stderr_path}" unless status.success?

      if arm == 'raw'
        observation = JSON.parse(File.readlines(stdout_path).last)
      else
        evidence = File.readlines(stdout_path).last.delete_prefix('Evidence: ').strip
        receipt = JSON.parse(File.read(File.join(evidence, 'receipt.json')))
        raise 'Wrapper did not pass' unless receipt['status'] == 'passed_scoped_journey'

        observation = receipt.fetch('observations').last
      end
      WoodsVerification::ResidentJourney.verify_report!(observation)
      sample = JSON.parse(File.read(metrics)).merge('arm' => arm, 'repetition' => repetition + 1,
                                                    'load_average' => load_average,
                                                    'checks' => observation['checks'].size)
      report[:samples] << sample
      File.write(File.join(output, 'comparison.json'), JSON.pretty_generate(report))
      puts JSON.generate(sample)
    end
  end
end
raise 'Candidate or verifier changed' unless identity_reader.send(:identity) == identity

report[:status] = 'complete'
report[:summary] = %w[raw wrapped].to_h do |arm|
  samples = report[:samples].select { |sample| sample['arm'] == arm }
  values = %w[wall_s user_s system_s max_rss_kib].to_h do |metric|
    sorted = samples.map { |sample| sample[metric] }.sort
    middle = sorted.length / 2
    median = sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    [metric, { median: median, min: sorted.first, max: sorted.last }]
  end
  [arm, values]
end
File.write(File.join(output, 'comparison.json'), JSON.pretty_generate(report))
puts "Comparison: #{output}"
