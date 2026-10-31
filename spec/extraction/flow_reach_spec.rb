# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'pathname'
require 'woods'
require 'woods/extraction/flow_reach'

# Which controllers' flow documents step into a set of units (#945).
RSpec.describe Woods::Extraction::FlowReach do
  let(:payload) { Pathname.new(Dir.mktmpdir('woods_flow_reach')) }
  let(:index) { { 'PostsController#show' => 'flows/posts_show.json', 'Post.created' => 'flows/post_created.json' } }

  before { FileUtils.mkdir_p(payload.join('flows')) }
  after { FileUtils.rm_rf(payload) }

  def reach
    described_class.new(payload_dir: payload, index_entries: index)
  end

  def write_inverse(data)
    File.write(payload.join('flows', 'by_unit.json'), JSON.generate(data))
  end

  def write_document(relative, entry_point, steps)
    File.write(payload.join(relative), JSON.generate('entry_point' => entry_point, 'steps' => steps))
  end

  context 'with a flow inverse' do
    before do
      write_inverse('Tracker' => { 'lib' => ['PostsController#show', 'Post.created'] },
                    'Post' => { 'model' => ['PostsController#show'] })
    end

    it 'names the controllers whose flows step into the units' do
      expect(reach.controllers_through(['Tracker'])).to eq(Set['PostsController'])
    end

    it 'ignores entry points that are not controller actions' do
      expect(reach.controllers_through(['Tracker']).to_a).not_to include('Post.created')
    end

    it 'answers nothing for units no flow steps into' do
      expect(reach.controllers_through(['Unrelated'])).to be_empty
    end

    it 'answers nothing without units, reading nothing' do
      FileUtils.rm_f(payload.join('flows', 'by_unit.json'))
      expect(reach.controllers_through([])).to be_empty
    end
  end

  context 'without a flow inverse (an older generation)' do
    before do
      write_document('flows/posts_show.json', 'PostsController#show',
                     [{ 'unit' => 'PostsController#show', 'type' => 'controller' },
                      { 'unit' => 'Tracker#track', 'type' => 'lib' },
                      { 'unit' => 'Looped', 'type' => 'cycle' }])
      write_document('flows/post_created.json', 'Post.created', [{ 'unit' => 'Post', 'type' => 'model' }])
    end

    it 'reads the expanded steps from the flow documents' do
      expect(reach.controllers_through(['Tracker'])).to eq(Set['PostsController'])
    end

    it 'does not count a cycle marker as a step' do
      expect(reach.controllers_through(['Looped'])).to be_empty
    end
  end

  it 'refuses a malformed inverse rather than answering from it' do
    write_inverse('Tracker' => ['PostsController#show'])
    expect { reach.controllers_through(['Tracker']) }.to raise_error(Woods::ExtractionError, /by_unit\.json/)
  end

  it 'refuses an unreadable flow document when there is no inverse' do
    File.write(payload.join('flows', 'posts_show.json'), '{not json')
    expect { reach.controllers_through(['Tracker']) }.to raise_error(Woods::ExtractionError, /posts_show\.json/)
  end
end
