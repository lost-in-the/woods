# frozen_string_literal: true

# Controlled probes of current static-map limits; writes observations to stdout.
require 'json'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/string/inflections'
require_relative '../../lib/woods/gem_mapper'
require_relative '../../lib/woods/gem_map_affected_specs'
require_relative '../../lib/woods/published_index'

module SelfMapBlindSpotsSpike
  FILES = {
    'lib/woods/target.rb' => 'module Probe; class Target; def run; :ok; end; end; end',
    'lib/woods/consumer.rb' => 'module Probe; class Consumer; def run; Target.new.run; end; end; end',
    'lib/woods/broken.rb' => 'class Broken; def run(',
    'spec/target_spec.rb' => "# Probe::Target is mentioned only in a comment\nRSpec.describe 'placeholder' do; end",
    'spec/support/helper.rb' => 'module Helper; def run; Probe::Target.new.run; end; end',
    'spec/helper_spec.rb' => "require_relative 'support/helper'\nRSpec.describe 'helper' do; include Helper; end"
  }.freeze

  def self.snapshot(output)
    Woods::PublishedIndex.open(output) do |index|
      {
        comment_dependents: index.dependents_of('Probe::Target'),
        helper_specs: Woods::GemMapAffectedSpecs.new(index).for(['spec/support/helper.rb']),
        broken_units: index.units.select { |unit| unit['file_path'] == 'lib/woods/broken.rb' },
        reported_parse_failures: index.manifest['parse_failures'],
        target_specs: affected(index)
      }
    end
  end

  def self.affected(index)
    Woods::GemMapAffectedSpecs.new(index).for(['lib/woods/target.rb'])
  end

  def self.run
    Dir.mktmpdir('woods-blind-spots') do |root|
      FILES.each do |path, source|
        destination = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(destination))
        File.write(destination, source)
      end
      output = File.join(root, 'index')
      Woods::GemMapper.new(root: root, output_dir: output).map!
      result = snapshot(output)
      File.delete(File.join(root, 'lib/woods/target.rb'))
      Woods::GemMapper.new(root: root, output_dir: output).map!
      Woods::PublishedIndex.open(output) { |index| result[:deleted_target_specs] = affected(index) }
      Woods::PublishedIndex.open(output, generation: 1) { |index| result[:retained_target_specs] = affected(index) }
      result
    end
  end
end

puts JSON.pretty_generate(SelfMapBlindSpotsSpike.run) if $PROGRAM_NAME == __FILE__
