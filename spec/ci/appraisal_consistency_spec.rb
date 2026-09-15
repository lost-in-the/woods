# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'yaml'

RSpec.describe 'Rails compatibility matrix' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:appraisals) do
    collector = Class.new do
      attr_reader :rows

      def initialize
        @rows = {}
      end

      def appraise(name, &block)
        @current = @rows[name] = {}
        instance_eval(&block)
      end

      def gem(name, *requirements)
        @current[name] = Gem::Requirement.new(requirements)
      end
    end.new
    collector.instance_eval(File.read(File.join(root, 'Appraisals')), 'Appraisals')
    collector.rows
  end

  it 'keeps the Appraisals, hand-maintained gemfiles, and CI Rails rows in agreement' do
    files = Dir[File.join(root, 'gemfiles/rails_*.gemfile')]
    names = files.map { |file| File.basename(file, '.gemfile').tr('_', '-') }
    expect(names.sort).to eq(appraisals.keys.sort)

    workflow = YAML.load_file(File.join(root, '.github/workflows/ci.yml'))
    matrix = workflow.fetch('jobs').fetch('rails-matrix').fetch('strategy').fetch('matrix').fetch('include')
    expect(matrix.map { |row| "rails-#{row.fetch('rails')}" }.uniq.sort).to eq(appraisals.keys.sort)

    files.each do |file|
      previous = ENV.fetch('WOODS_SQLITE3_REQ', nil)
      ENV.delete('WOODS_SQLITE3_REQ')
      dsl = Bundler::Dsl.new
      dsl.eval_gemfile(file)
      dependencies = dsl.dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }
      name = File.basename(file, '.gemfile').tr('_', '-')
      appraisals.fetch(name).each do |gem_name, requirement|
        expect(dependencies.fetch(gem_name)).to eq(requirement), "#{name}: #{gem_name} drifted from Appraisals"
      end
      expect(dependencies).to have_key('woods')
      expect(dependencies).to have_key('rspec')
      next unless Gem::Version.new(name.delete_prefix('rails-')) < Gem::Version.new('7.1')

      expect(dependencies.fetch('sqlite3')).to eq(Gem::Requirement.new('~> 1.4'))
      expect(dependencies.fetch('concurrent-ruby')).to eq(Gem::Requirement.new('< 1.3.5'))
    ensure
      previous.nil? ? ENV.delete('WOODS_SQLITE3_REQ') : ENV['WOODS_SQLITE3_REQ'] = previous
    end
  end
end
