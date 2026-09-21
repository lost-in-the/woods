# frozen_string_literal: true

# Development reproduction, not a packaged Woods command.
# Run from the Woods checkout whose implementation you want to inspect:
# BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle exec ruby -Ilib \
#   /absolute/path/to/this/file.rb
# Exit 1 means different records were emitted by two equivalent Rails boots.

require 'json'

def verify_callback(mailer)
  mailer.new.process(:sample)
  raise 'Registered object callback was not invoked'
rescue RuntimeError => e
  raise unless e.message == 'object callback ran'
end

if ARGV == ['--child']
  require 'logger'
  require 'rails'
  require 'action_controller/railtie'
  require 'action_mailer/railtie'
  require 'tmpdir'
  require 'fileutils'
  require 'woods'
  require 'woods/extracted_unit'
  require 'woods/extractors/mailer_extractor'

  app = Class.new(Rails::Application)
  Object.const_set(:MailerObjectProbeApplication, app)
  Dir.mktmpdir('woods_object_callback') do |root|
    FileUtils.mkdir_p(File.join(root, 'app/mailers'))
    path = File.join(root, 'app/mailers/probe_mailer.rb')
    File.write(path, <<~RUBY)
      class MailerAuditCallback
        def before(_mailer)
          raise 'object callback ran'
        end
      end
      class ProbeMailer < ActionMailer::Base
        before_action MailerAuditCallback.new
        def sample; end
      end
    RUBY
    app.config.root = root
    app.config.eager_load = false
    app.config.secret_key_base = 'public-disposable-probe-value'
    app.config.logger = Logger.new(IO::NULL)
    app.initialize!
    require path
    unit = Woods::Extractors::MailerExtractor.new.extract_all.find { |item| item.identifier == 'ProbeMailer' }
    raise 'Missing mailer' unless unit

    # Extraction above must not execute the callback. Normal processing must.
    verify_callback(ProbeMailer)
    puts JSON.generate(rails: Rails.version, callbacks: unit.metadata.fetch(:callbacks),
                       source_hash: unit.to_h.fetch(:source_hash))
  end
else
  require 'open3'
  records = 2.times.map do
    output, error, status = Open3.capture3(RbConfig.ruby, '-Ilib', File.expand_path(__FILE__), '--child')
    abort "Child failed: #{error}" unless status.success?
    JSON.parse(output.lines.last)
  end
  stable = records[0] == records[1]
  puts JSON.pretty_generate(stable: stable, records: records)
  exit(stable ? 0 : 1)
end
