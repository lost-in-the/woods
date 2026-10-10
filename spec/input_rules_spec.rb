# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/input_rules'
require 'woods/hooks/rule_projection'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Woods::InputRules do
  subject(:rules) { described_class.new }

  it 'selects fresh full extraction for boot inputs and removals' do
    %w[config/initializers/cache.rb config/database.yml db/schema.rb Gemfile.lock .env.local].each do |path|
      expect(rules.action(path)).to eq(:full)
    end
    expect(rules.action('app/controllers/posts_controller.rb', operation: 'delete')).to eq(:full)
    expect(rules.action('app/services/old.rb', operation: 'move')).to eq(:full)
  end

  it 'selects incremental work for runtime, per-file and whole-app inputs' do
    %w[app/services/pay.rb app/controllers/posts_controller.rb app/jobs/pay_job.rb
       app/views/posts/index.html.erb app/models/concerns/payable.rb config/locales/en.yml
       spec/models/post_spec.rb test/models/post_test.rb lib/pay.rb spec/factories/posts.rb
       config/routes.rb db/views/posts_v01.sql].each do |path|
      expect(rules.action(path)).to eq(:incremental), path
    end
    %w[README.md docs/guide.md tmp/output.json spec/README.md vendor/package.yml].each do |path|
      expect(rules.action(path)).to eq(:ignore), path
    end
  end

  it 'treats Ruby under a declared source root as incremental input, removals as full (F15)' do
    declared = described_class.new(extra_roots: %w[domain packs/billing])
    expect(declared.action('domain/billing/ledger.rb')).to eq(:incremental)
    expect(declared.action('packs/billing/app/models/invoice.rb')).to eq(:incremental)
    expect(declared.action('domain/billing/ledger.rb', operation: 'delete')).to eq(:full)
    expect(declared.action('domain/README.md')).to eq(:ignore)
    expect(declared.action('domains/other.rb')).to eq(:ignore)
    expect(rules.action('domain/billing/ledger.rb')).to eq(:ignore)
  end

  it 'reads declared roots from the published index manifest, and none from a missing or odd one' do
    Dir.mktmpdir('woods-input-rules-index') do |dir|
      expect(described_class.for_index(dir).extra_roots).to eq([])

      payload = File.join(dir, 'payloads', 'gen-1')
      FileUtils.mkdir_p(payload)
      File.write(File.join(dir, 'generation.json'),
                 JSON.generate('number' => 1, 'token' => 'abc', 'payload' => 'payloads/gen-1'))
      File.write(File.join(payload, 'source_inputs.json'), JSON.generate('extra_roots' => ['domain']))
      expect(described_class.for_index(dir).extra_roots).to eq(['domain'])
      expect(described_class.for_index(dir).action('domain/billing/ledger.rb')).to eq(:incremental)

      File.write(File.join(payload, 'source_inputs.json'), JSON.generate('extra_roots' => 'domain'))
      expect(described_class.for_index(dir).extra_roots).to eq([])
      File.write(File.join(payload, 'source_inputs.json'), '{not json')
      expect(described_class.for_index(dir).extra_roots).to eq([])
    end
  end

  it 'lets the portable predicate honour declared roots handed over in WOODS_DECLARED_ROOTS' do
    declared = described_class.new(extra_roots: %w[domain packs/billing])
    paths = %w[domain/billing/ledger.rb domain/README.md packs/billing/app/models/invoice.rb domains/other.rb
               app/models/post.rb]
    script = 'source "$1"; shift; for path in "$@"; do woods_input_action "$path"; printf "\\n"; done'
    projection = File.expand_path('../plugin/hooks/woods-input-rules.sh', __dir__)
    out, err, status = Open3.capture3({ 'WOODS_DECLARED_ROOTS' => 'domain:packs/billing' },
                                      'bash', '-c', script, '--', projection, *paths)
    expect(status).to be_success, err
    expect(out.lines.map(&:strip)).to eq(paths.map { |path| declared.action(path).to_s })
    with_operation = 'source "$1"; woods_input_action "$2" "$3"'
    out, = Open3.capture3({ 'WOODS_DECLARED_ROOTS' => 'domain' }, 'bash', '-c', with_operation, '--', projection,
                          'domain/billing/ledger.rb', 'delete')
    expect(out.strip).to eq('full')
  end

  it 'keeps the portable plugin rules identical to their generated projection' do
    generated = File.expand_path('../plugin/hooks/woods-input-rules.sh', __dir__)
    expect(File.read(generated)).to eq(Woods::Hooks::RuleProjection.new.render)
  end

  it 'projects no rule that has no path surface, and names the one it leaves to the daemon' do
    rendered = Woods::Hooks::RuleProjection.new.render

    expect(rendered).not_to include('if { { false; }; }; then')
    expect(rendered).to include('# external_consumers: the declared file is configuration')
  end

  it 'agrees with the portable predicate for every authoritative rule and near misses' do
    dispatcher_rules = Woods::PathDispatcher.runtime_rules + Woods::PathDispatcher.file_rules +
                       Woods::PathDispatcher.whole_app_rules
    paths = dispatcher_rules.flat_map do |rule|
      rule.exact_paths.to_a + rule.basenames.to_a.flat_map do |name|
        [name, "packs/billing/#{name}", "vendor/#{name}"]
      end +
        rule.dirs.to_a.flat_map do |dir|
          (rule.extensions || ['.txt']).flat_map do |extension|
            ["#{dir}/sample#{extension}", "#{dir}/nested/sample#{extension}",
             "#{dir}#{rule.require_segment}/sample#{extension}", "#{dir}/sample.txt"]
          end
        end
    end
    paths += Woods::ReloadPolicy::RESTART_PATHS + Woods::ReloadPolicy::RESTART_DIRECTORIES.map { |dir| "#{dir}/x.rb" }
    paths += %w[config/settings.yml config/settings.yaml config/settings/local.yml .env .env.local
                config/cable.yaml config/sidekiq_cron.yml README.md config/locales/en.yml]
    paths.uniq!
    script = 'source "$1"; shift; for path in "$@"; do woods_input_action "$path"; printf "\\n"; done'
    projection = File.expand_path('../plugin/hooks/woods-input-rules.sh', __dir__)
    out, err, status = Open3.capture3('bash', '-c', script, '--', projection, *paths)
    expect(status).to be_success, err
    expect(out.lines.map(&:strip)).to eq(paths.map { |path| rules.action(path).to_s })
  end
end
