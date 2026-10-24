# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extracted_unit'
require 'woods/source_size'

RSpec.describe Woods::SourceSize do
  around do |example|
    Dir.mktmpdir('woods-source-size') do |dir|
      @root = dir
      example.run
    end
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def unit(type, file_path)
    Woods::ExtractedUnit.new(type: type, identifier: 'Unit', file_path: file_path)
  end

  it 'counts every line and the lines with code, whatever the encoding' do
    expect(described_class.count("class A\n\n  # note\n  \t\nend\n")).to eq(lines: 5, loc: 3)
    expect(described_class.count("a\nb")).to eq(lines: 2, loc: 2)
    expect(described_class.count('')).to eq(lines: 0, loc: 0)
    expect(described_class.count("caf\xC3\xA9\n\xFF\n")).to eq(lines: 2, loc: 2)
  end

  it 'records the size of an application unit read from a file under the root' do
    u = unit(:model, write('app/models/user.rb', "class User\nend\n"))
    described_class.record(u, root: @root)
    expect(u.metadata[:source_size]).to eq(lines: 2, loc: 2)
  end

  it 'resolves a relative file path against the root' do
    write('app/services/pay.rb', "class Pay\n\nend\n")
    expect(described_class.for_unit(unit(:service, 'app/services/pay.rb'), root: @root)).to eq(lines: 3, loc: 2)
  end

  it 'records nothing for framework, route and configuration units, or files outside the root' do
    outside = Dir.mktmpdir('woods-outside')
    gem_file = File.join(outside, 'blob.rb')
    File.write(gem_file, "class Blob\nend\n")
    routes = write('config/routes.rb', "Rails.application.routes.draw do\nend\n")
    expect(described_class.for_unit(unit(:model, gem_file), root: @root)).to be_nil
    expect(described_class.for_unit(unit(:route, routes), root: @root)).to be_nil
    expect(described_class.for_unit(unit(:configuration, routes), root: @root)).to be_nil
    expect(described_class.for_unit(unit(:rails_source, routes), root: @root)).to be_nil
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  it 'records nothing for a class another unit generates, whose file is the declaring unit\'s' do
    u = unit(:job, write('app/models/widget.rb', "class Widget\n  async_method :sync\nend\n"))
    u.metadata[:generated] = true
    expect(described_class.for_unit(u, root: @root)).to be_nil
  end

  it 'clears a size a unit no longer has, such as a deleted file' do
    u = unit(:model, File.join(@root, 'app/models/gone.rb'))
    u.metadata[:source_size] = { lines: 9, loc: 9 }
    described_class.record(u, root: @root)
    expect(u.metadata).not_to have_key(:source_size)
  end
end
