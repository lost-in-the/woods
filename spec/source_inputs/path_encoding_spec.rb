# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

RSpec.describe 'Source path byte handling across process locales' do
  let(:probe) do
    <<~RUBY
      require 'woods'
      require 'fileutils'
      require 'woods/source_inputs/session'
      require 'woods/source_inputs/status'
      require 'woods/watch/tree_scan'
      require 'woods/mcp/server'
      root, output = ARGV
      key = Woods::SourceInputs::PrivateKey.new(output_dir: output, create: true)
      capture = Woods::SourceInputs::Scanner.new(root: root, output_dir: output, key: key).call
      scopes = capture.fetch('scope_paths').transform_values do |paths|
        paths.to_h { |path| [path, capture.fetch('files').fetch(path)] }
      end
      baseline = Woods::SourceInputs::Manifest.build(snapshot: capture, scopes: scopes,
                                                     boot_verified: true, generation: 1)
      payload = File.join(output, 'payloads/00000001')
      FileUtils.mkdir_p(payload)
      File.binwrite(File.join(payload, 'source_inputs.json'), JSON.generate(baseline.data))
      File.binwrite(File.join(payload, 'manifest.json'), JSON.generate(counts: {}))
      Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: 'payloads/00000001')
      session = Woods::SourceInputs::Session.new(root: root, output_dir: output, baseline_path: nil, operation: 'full')
      source_read = session.read_source(capture.fetch('files').keys.first)
      manifest = session.finish(generation: 2, eager_load_complete: true)
      status = Woods::SourceInputs::Status.new(output_dir: output, payload_dir: payload, generation: 1, mode: 'deep').call
      watched = Woods::Watch::TreeScan.files(root: root, ignored: ['index'])
      server = Woods::MCP::Server.build(index_dir: output, response_format: :json, warmup: false)
      response = server.instance_variable_get(:@tools).fetch('woods_status').call(source_check: 'deep', server_context: {})
      mcp_status = JSON.parse(response.content.first.fetch(:text)).dig('index', 'source_freshness')
      puts JSON.generate(capture: capture, manifest: manifest.data, status: status, watched: watched,
                         source_read: source_read, mcp_status: mcp_status)
    RUBY
  end

  %w[C C.UTF-8].each do |locale|
    [false, true].each do |invalid|
      it "preserves UTF-8 filenames and #{invalid ? 'unknown' : 'complete'} proof under #{locale}" do
        Dir.mktmpdir('woods-path-encoding') do |parent|
          root = File.join(parent, 'café')
          source = File.join(root, 'app/services/résumé.rb')
          FileUtils.mkdir_p(File.dirname(source))
          File.binwrite(source, 'class Example; end')
          if invalid
            FileUtils.mkdir_p(File.join(root, 'public/uploads'))
            File.binwrite(File.join(root.b, 'public/uploads/bad_'.b + "\xFF".b), 'unrelated')
          end
          env = { 'LC_ALL' => locale, 'LANG' => locale, 'WOODS_NO_UPDATE_CHECK' => '1' }
          stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-Ilib', '-e', probe, root,
                                                  File.join(root, 'index'))
          expect(status).to be_success, stderr
          result = JSON.parse(stdout.force_encoding(Encoding::UTF_8))
          expect(result['capture']['complete']).to be(!invalid)
          expect(result['capture']['files'].keys).to eq(['app/services/résumé.rb'])
          expect(result['manifest']['complete']).to be(!invalid)
          expect(result['watched']).to eq([source])
          expect(result['source_read']['path']).to eq('app/services/résumé.rb')
          expect(result['status']['state']).to eq(invalid ? 'unknown' : 'current'), result['status'].inspect
          expect(result['mcp_status']['state']).to eq(invalid ? 'unknown' : 'current'), result['mcp_status'].inspect
          next unless invalid

          expect(result['status']['reasons']).to include('undecodable_source_path')
          expect(result['mcp_status']['reasons']).to include('undecodable_source_path')
        end
      end
    end
  end
end
