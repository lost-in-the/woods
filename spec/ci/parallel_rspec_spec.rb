# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../script/parallel_rspec'

RSpec.describe ParallelRspec do
  describe '.split' do
    let(:timings) do
      { 'a_spec.rb' => 8.0, 'b_spec.rb' => 5.0, 'c_spec.rb' => 4.0, 'd_spec.rb' => 3.0, 'e_spec.rb' => 2.0 }
    end

    it 'balances the slowest files across groups' do
      groups = described_class.split(timings.keys, timings, 2)

      expect(groups.map { |group| group.sum { |file| timings.fetch(file) } }).to contain_exactly(11.0, 11.0)
    end

    it 'places every file exactly once' do
      groups = described_class.split(timings.keys, timings, 3)

      expect(groups.flatten).to match_array(timings.keys)
    end

    it 'treats files without a recorded timing as average cost' do
      groups = described_class.split(%w[known_spec.rb new_spec.rb], { 'known_spec.rb' => 30.0 }, 2)

      expect(groups).to contain_exactly(['known_spec.rb'], ['new_spec.rb'])
    end

    it 'never returns an empty group' do
      expect(described_class.split(%w[only_spec.rb], {}, 4)).to eq([['only_spec.rb']])
    end
  end

  describe '.timings_from' do
    it 'sums example seconds per file' do
      Dir.mktmpdir do |dir|
        report = File.join(dir, 'rspec.json')
        File.write(report, JSON.generate('examples' => [
                                           { 'file_path' => './spec/a_spec.rb', 'run_time' => 1.234 },
                                           { 'file_path' => './spec/a_spec.rb', 'run_time' => 2.0 },
                                           { 'file_path' => './spec/b_spec.rb', 'run_time' => 0.5 }
                                         ]))

        expect(described_class.timings_from(report)).to eq('spec/a_spec.rb' => 3.23, 'spec/b_spec.rb' => 0.5)
      end
    end
  end

  describe 'script/parallel-rspec' do
    let(:script) { File.expand_path('../../script/parallel-rspec', __dir__) }

    def write_spec(dir, name, body)
      File.write(File.join(dir, name), "require 'spec_helper'\nRSpec.describe('#{name}') { #{body} }\n")
    end

    def run_script(dir, *files)
      env = { 'WOODS_PARALLEL_PROCESSES' => '2', 'WOODS_PARALLEL_REPORT_DIR' => File.join(dir, 'report'),
              'COVERAGE' => nil, 'CI' => nil }
      Open3.capture2e(env, RbConfig.ruby, script, *files.map { |file| File.join(dir, file) })
    end

    it 'gives each process its own TEST_ENV_NUMBER and TMPDIR' do
      Dir.mktmpdir do |dir|
        %w[one_spec.rb two_spec.rb].each do |name|
          write_spec(dir, name, <<~RUBY)
            it('records its scratch space') do
              File.write(File.join('#{dir}', "\#{ENV['TEST_ENV_NUMBER']}.txt"), Dir.tmpdir)
            end
          RUBY
        end

        output, status = run_script(dir, 'one_spec.rb', 'two_spec.rb')

        expect(status).to be_success, output
        recorded = Dir[File.join(dir, '[0-9].txt')].to_h { |path| [File.basename(path, '.txt'), File.read(path)] }
        expect(recorded.keys).to contain_exactly('1', '2')
        expect(recorded.values.uniq.size).to eq(2)
      end
    end

    it 'fails when any process fails and still reports the others' do
      Dir.mktmpdir do |dir|
        write_spec(dir, 'good_spec.rb', "it('passes') { expect(1).to eq(1) }")
        write_spec(dir, 'bad_spec.rb', "it('fails') { expect(1).to eq(2) }")

        output, status = run_script(dir, 'good_spec.rb', 'bad_spec.rb')

        expect(status).not_to be_success
        expect(output).to include('2 examples, 1 failures')
        summary = JSON.parse(File.read(File.join(dir, 'report', 'test_results.json')))
        expect(summary.fetch('failures').map { |example| example['full_description'] }).to eq(['bad_spec.rb fails'])
      end
    end
  end
end
