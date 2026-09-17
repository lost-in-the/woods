# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/input_rules'
require 'woods/hooks/rule_projection'
require 'open3'

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

  it 'keeps the portable plugin rules identical to their generated projection' do
    generated = File.expand_path('../plugin/hooks/woods-input-rules.sh', __dir__)
    expect(File.read(generated)).to eq(Woods::Hooks::RuleProjection.new.render)
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
