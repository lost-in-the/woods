# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

# Separate process in the Rails matrix: real encrypted credentials, Active
# Record and MCP dispatch must not share the dummy app's Rails singleton.
RSpec.describe 'Console encrypted credential rotation', :booted_app do
  def old_secret
    'synthetic-old-signing-material-audit'
  end

  def new_secret
    'synthetic-new-signing-material-audit'
  end

  before(:all) do
    require 'logger'
    require 'rails'
    require 'active_record'
    require 'active_support/encrypted_configuration'
    require 'woods'
    require 'woods/console/server'

    @root = Dir.mktmpdir('woods-console-rotation')
    @content_path = File.join(@root, 'credentials.yml.enc')
    @key_path = File.join(@root, 'master.key')
    @master_key = ActiveSupport::EncryptedFile.generate_key
    reset_credentials
    app = Class.new(Rails::Application)
    app.config.root = @root
    app.config.eager_load = false
    app.config.logger = Logger.new(File::NULL)
    app.config.secret_key_base = 'woods-synthetic-rotation-fixture'
    app.config.credentials.content_path = @content_path
    app.config.credentials.key_path = @key_path
    app.initialize!
    @rails_app = Rails.application
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.console_credential_rotation_warning = false
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: File.join(@root, 'fixture.sqlite3'))
    ActiveRecord::Base.connection.create_table(:woods_rotation_notes) { |table| table.string :body }
    Object.const_set(:WoodsRotationNote, Class.new(ActiveRecord::Base))
    @record = WoodsRotationNote.create!(body: old_secret)
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
    Object.send(:remove_const, :WoodsRotationNote)
    Woods.configuration = @original_config
    FileUtils.remove_entry(@root)
  end

  before do
    reset_credentials
    @record.update!(body: old_secret)
    @server = build_server
    expect(response(@server)).to include('[REDACTED:credential]')
  end

  def reset_credentials
    File.write(@key_path, @master_key)
    write_credentials(old_secret)
  end

  def credentials
    ActiveSupport::EncryptedConfiguration.new(
      config_path: @content_path, key_path: @key_path,
      env_key: 'WOODS_SYNTHETIC_ROTATION_KEY', raise_if_missing_key: true
    )
  end

  def write_credentials(value)
    credentials.write({ webhook_signing_key: value }.to_yaml)
  end

  def build_server
    Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(registry: { 'WoodsRotationNote' => %w[id body] }),
      safe_context: Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool),
      model_tables: { 'WoodsRotationNote' => 'woods_rotation_notes' }
    )
  end

  def response(server)
    request = {
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'console_find', arguments: { model: 'WoodsRotationNote', id: @record.id } }
    }
    result = JSON.parse(server.handle_json(JSON.generate(request)))
    expect(result.dig('result', 'isError')).to be false
    result.dig('result', 'content').map { |part| part.fetch('text') }.join
  end

  def rebuild
    Woods::Console::Server.rebuild_credential_index(rails_app: @rails_app)
  end

  it 'reads the rotated file without changing Rails cached application credentials' do
    cached = @rails_app.credentials.config
    write_credentials(new_secret)
    @record.update!(body: new_secret)

    index = rebuild

    expect(index.match?(new_secret)).to be true
    expect(response(@server)).to include('[REDACTED:credential]')
    expect(response(@server)).not_to include(new_secret)
    expect(@rails_app.credentials.config).to equal(cached)
    expect(cached[:webhook_signing_key]).to eq(old_secret)
  end

  it 'refreshes all live embedded servers' do
    second = build_server
    write_credentials(new_secret)
    @record.update!(body: new_secret)
    rebuild

    [@server, second].each do |server|
      expect(response(server)).to include('[REDACTED:credential]')
      expect(response(server)).not_to include(new_secret)
    end
  end

  it 'builds a later server from current credentials rather than the Rails cache' do
    write_credentials(new_secret)
    @record.update!(body: new_secret)

    expect(response(build_server)).to include('[REDACTED:credential]')
    expect(response(build_server)).not_to include(new_secret)
  end

  it 'reads a rotated master key without reusing the cached decryptor' do
    File.write(@key_path, ActiveSupport::EncryptedFile.generate_key)
    write_credentials(new_secret)
    @record.update!(body: new_secret)
    rebuild

    expect(response(@server)).not_to include(new_secret)
    expect(response(@server)).to include('[REDACTED:credential]')
  end

  it 'retains the last index and raises when the encrypted file is corrupted' do
    File.write(@content_path, 'not-encrypted-credentials')

    expect { rebuild }.to raise_error(ActiveSupport::MessageEncryptor::InvalidMessage)
    expect(response(@server)).not_to include(old_secret)
  end

  it 'retains the last index and raises when the encrypted file is deleted' do
    File.unlink(@content_path)

    expect { rebuild }.to raise_error(ActiveSupport::EncryptedFile::MissingContentError)
    expect(response(@server)).not_to include(old_secret)
  end

  it 'retains the last index and raises when the key is missing' do
    File.unlink(@key_path)

    expect { rebuild }.to raise_error(ActiveSupport::EncryptedFile::MissingKeyError)
    expect(response(@server)).not_to include(old_secret)
  end

  it 'retains the last index and raises when the decrypted YAML is invalid' do
    ActiveSupport::EncryptedFile.new(
      content_path: @content_path, key_path: @key_path,
      env_key: 'WOODS_SYNTHETIC_ROTATION_KEY', raise_if_missing_key: true
    ).write("secret: [unterminated\n")

    expect { rebuild }.to raise_error(StandardError)
    expect(response(@server)).not_to include(old_secret)
  end

  it 'allows an intentionally empty valid credential file to replace the index' do
    credentials.write("{}\n")

    expect(rebuild).to be_empty
    expect(response(@server)).to include(old_secret)
  end
end
