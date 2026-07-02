# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/svelte_flow/unit_source'

RSpec.describe Woods::SvelteFlow::UnitSource do
  describe '.resolve' do
    it 'reads the live file when the unit file path exists' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'order.rb')
        File.write(path, "class Order\n  # edited after extraction\nend\n")
        unit = { 'file_path' => path, 'source_code' => "class Order\nend\n" }

        result = described_class.resolve(unit)
        expect(result['sourceCode']).to include('edited after extraction')
        expect(result['live']).to be(true)
      end
    end

    it 'falls back to the stored snapshot when the file is missing' do
      unit = { 'file_path' => '/nonexistent/order.rb', 'source_code' => "class Order\nend\n" }
      result = described_class.resolve(unit)
      expect(result['sourceCode']).to eq("class Order\nend\n")
      expect(result['live']).to be(false)
    end

    it 'returns nil source when neither file nor snapshot exists' do
      expect(described_class.resolve({ 'file_path' => nil })['sourceCode']).to be_nil
    end
  end

  describe '.strip_annotate_header' do
    let(:annotated) do
      <<~RUBY
        # == Schema Information
        #
        # Table: accounts
        #
        # Columns:
        #  id  integer
        #  country_id  integer

        class Account < ApplicationRecord
        end
      RUBY
    end

    it 'removes a leading annotate block and its trailing blank lines' do
      expect(described_class.strip_annotate_header(annotated))
        .to eq("class Account < ApplicationRecord\nend\n")
    end

    it 'preserves comment lines above the block (magic comments)' do
      source = "# frozen_string_literal: true\n#{annotated}"
      stripped = described_class.strip_annotate_header(source)
      expect(stripped).to start_with("# frozen_string_literal: true\n")
      expect(stripped).not_to include('Schema Information')
    end

    it 'leaves source without an annotate block unchanged' do
      source = "class Account\nend\n"
      expect(described_class.strip_annotate_header(source)).to eq(source)
    end

    it 'leaves a block that is not in the leading comment region unchanged' do
      source = "class Account\nend\n# == Schema Information\n# Table: accounts\n"
      expect(described_class.strip_annotate_header(source)).to eq(source)
    end
  end
end
