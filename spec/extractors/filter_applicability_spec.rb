# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support'
require 'active_support/callbacks'
require 'abstract_controller'
require 'active_support/concern'
require 'woods'
require 'woods/extractors/controller_extractor'
require 'woods/extractors/mailer_extractor'

# Resolved filter applicability (W-8, woods#758): for each filter in a
# controller's chain, the admitted actions it applies to after only/except,
# whether an if/unless condition still decides it at request time, and the
# class or concern that declared it.
#
# The fixtures are real AbstractController classes loaded from files under a
# temporary application root, so the callback chain, its ActionFilter
# conditions, skip_before_action's merged callbacks and const_source_location
# are the framework's and Ruby's own answers.
RSpec.describe Woods::Extractors::ControllerExtractor, 'filter applicability' do
  let(:root) { Dir.mktmpdir('woods_filter_applicability') }
  let(:actions) { %w[index show edit health] }
  let(:constants) { %i[W8Auditing W8Authenticating W8BaseController W8PostsController W8DigestMailer] }

  let(:extractor) do
    routes = double('Routes', routes: [], named_routes: {})
    stub_const('Rails', double('Rails', application: double('Application', routes: routes),
                                        root: Pathname.new(root)))
    described_class.new
  end

  def write(relative, contents)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  before do
    load write('app/controllers/concerns/w8_authenticating.rb', <<~RUBY)
      module W8Authenticating
        extend ActiveSupport::Concern

        included do
          before_action :authenticate, unless: :public_page?
          before_action { @stamped = true }
        end
      end
    RUBY
    load write('app/controllers/concerns/w8_auditing.rb', <<~RUBY)
      module W8Auditing
        extend ActiveSupport::Concern

        included do
          after_action :audit, only: %i[show edit]
        end
      end
    RUBY
    load write('app/controllers/w8_base_controller.rb', <<~RUBY)
      class W8BaseController < AbstractController::Base
        include AbstractController::Callbacks
        include W8Authenticating

        before_action :set_locale
        before_action :track, except: :health
      end
    RUBY
    load write('app/controllers/w8_posts_controller.rb', <<~RUBY)
      class W8PostsController < W8BaseController
        include W8Auditing

        before_action :set_post, only: %i[show edit]
        skip_before_action :track, only: :index
        around_action :with_timing, if: -> { true }

        def index; end
        def show; end
        def edit; end
        def health; end
      end
    RUBY
  end

  after do
    constants.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    FileUtils.remove_entry(root)
  end

  def chain
    extractor.send(:extract_filter_chain, W8PostsController, actions: actions)
  end

  def filter(name)
    chain.find { |entry| entry[:filter] == name } || raise("no filter #{name}")
  end

  it 'attributes a filter declared in the controller to the controller' do
    expect(filter(:set_post)).to include(owner: 'W8PostsController', applies_to: %w[show edit],
                                         applicability: 'resolved')
  end

  it 'attributes an inherited filter to the superclass that declared it' do
    expect(filter(:set_locale)).to include(owner: 'W8BaseController', applies_to: actions,
                                           applicability: 'resolved')
  end

  it 'attributes a filter a concern declares to the concern, not the including class' do
    expect(filter(:authenticate)).to include(owner: 'W8Authenticating')
    expect(filter(:audit)).to include(owner: 'W8Auditing', applies_to: %w[show edit], applicability: 'resolved')
  end

  it 'attributes a proc filter to the module whose source holds the block' do
    stamp = chain.find { |entry| entry[:filter].to_s.start_with?('#<Proc') }

    expect(stamp).to include(owner: 'W8Authenticating', applies_to: actions, applicability: 'resolved')
  end

  it 'resolves a skip_before_action scope against the inherited declaration' do
    expect(filter(:track)).to include(owner: 'W8BaseController', applies_to: %w[show edit],
                                      applicability: 'resolved', except: %w[health index])
  end

  it 'never resolves an if/unless condition: the filter stays conditional on the admitted actions' do
    expect(filter(:authenticate)).to include(applies_to: actions, applicability: 'conditional',
                                             unless: ':public_page?')
    expect(filter(:with_timing)).to include(owner: 'W8PostsController', applies_to: actions,
                                            applicability: 'conditional')
  end

  it 'keeps the chain order and the declared only/except/if/unless evidence' do
    names = chain.map { |entry| entry[:filter].to_s.start_with?('#<Proc') ? :proc : entry[:filter] }

    expect(names).to eq(%i[authenticate proc set_locale track audit set_post with_timing])
    expect(filter(:set_post)).to include(kind: :before, only: %w[edit show])
    expect(filter(:audit)).to include(kind: :after, only: %w[edit show])
  end

  it 'leaves the chain without applicability when no action list is given' do
    expect(extractor.send(:extract_filter_chain, W8PostsController).first.keys)
      .not_to include(:owner, :applies_to, :applicability)
  end

  # Mailers share AbstractController::Callbacks, so their callbacks carry the
  # same three fields over the mailer's actions.
  describe 'mailer callbacks' do
    let(:mailer_extractor) do
      routes = double('Routes', routes: [], named_routes: {})
      stub_const('Rails', double('Rails', application: double('Application', routes: routes),
                                          root: Pathname.new(root)))
      Woods::Extractors::MailerExtractor.new
    end

    before do
      load write('app/mailers/w8_digest_mailer.rb', <<~RUBY)
        class W8DigestMailer < W8BaseController
          before_action :load_digest, except: :weekly

          def daily; end
          def weekly; end
        end
      RUBY
    end

    it 'publishes owner, applies_to and applicability on each callback' do
      callbacks = mailer_extractor.send(:extract_callbacks, W8DigestMailer, %w[daily weekly])

      expect(callbacks.find { |cb| cb[:filter] == 'load_digest' })
        .to include(type: :before_action, except: %w[weekly], owner: 'W8DigestMailer', applies_to: %w[daily],
                    applicability: 'resolved')
      expect(callbacks.find { |cb| cb[:filter] == 'authenticate' })
        .to include(owner: 'W8Authenticating', applies_to: %w[daily weekly], applicability: 'conditional')
    end
  end

  # Rails 6.0 normalizes only/except into a proc closing over the action set
  # (AbstractController::Callbacks#_normalize_callback_option) rather than an
  # ActionFilter. The proc is read through its binding, never called.
  describe 'Rails 6.0 only/except procs' do
    def legacy_condition(actions, file: 'abstract_controller/callbacks.rb')
      path = write("gems/actionpack/lib/#{file}", <<~RUBY)
        ->(actions) { _from = actions.to_set; proc { |c| raise 'never called' if c; _from } }
      RUBY
      eval(File.read(path), TOPLEVEL_BINDING, path, 1).call(actions) # rubocop:disable Security/Eval
    end

    it 'reads the action set of the framework proc' do
      expect(extractor.send(:extract_action_filter_actions, legacy_condition(%w[show]))).to eq(%w[show])
    end

    it 'does not read a proc from elsewhere that happens to close over _from' do
      condition = legacy_condition(%w[show], file: 'my_gem/callbacks.rb')

      expect(extractor.send(:extract_action_filter_actions, condition)).to be_nil
    end
  end
end
