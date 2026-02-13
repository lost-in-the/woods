# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ast/parser'
require 'codebase_index/ast/call_site_extractor'

RSpec.describe CodebaseIndex::Ast::CallSiteExtractor do
  subject(:extractor) { described_class.new }

  let(:parser) { CodebaseIndex::Ast::Parser.new }

  describe '#extract' do
    it 'extracts basic method calls' do
      source = <<~RUBY
        def create
          user = User.find(id)
          user.save
        end
      RUBY

      root = parser.parse(source)
      calls = extractor.extract(root)

      method_names = calls.map { |c| c[:method_name] }
      expect(method_names).to include('find')
      expect(method_names).to include('save')
    end

    it 'extracts receiver information' do
      root = parser.parse("User.find(1)")
      calls = extractor.extract(root)

      call = calls.find { |c| c[:method_name] == 'find' }
      expect(call[:receiver]).to eq('User')
    end

    it 'returns nil receiver for bare method calls' do
      root = parser.parse("do_something()")
      calls = extractor.extract(root)

      call = calls.find { |c| c[:method_name] == 'do_something' }
      expect(call[:receiver]).to be_nil
    end

    it 'preserves source-order by line number' do
      source = <<~RUBY
        def create
          first_call
          second_call
          third_call
        end
      RUBY

      root = parser.parse(source)
      calls = extractor.extract(root)

      # Filter to the three calls we care about
      relevant = calls.select { |c| c[:method_name].include?('_call') }
      expect(relevant.map { |c| c[:method_name] }).to eq(%w[first_call second_call third_call])
    end

    it 'extracts chained calls' do
      root = parser.parse("User.where(active: true).order(:name)")
      calls = extractor.extract(root)

      method_names = calls.map { |c| c[:method_name] }
      expect(method_names).to include('where')
      expect(method_names).to include('order')
    end

    it 'marks block-passing calls with block: true' do
      source = <<~RUBY
        items.each do |item|
          process(item)
        end
      RUBY

      root = parser.parse(source)
      calls = extractor.extract(root)

      each_call = calls.find { |c| c[:method_name] == 'each' }
      expect(each_call[:block]).to be true

      process_call = calls.find { |c| c[:method_name] == 'process' }
      expect(process_call[:block]).to be false
    end

    it 'extracts calls from within blocks' do
      source = <<~RUBY
        Checkout.transaction do
          cart.lock!
          checkout = Checkout.create!
        end
      RUBY

      root = parser.parse(source)
      calls = extractor.extract(root)

      method_names = calls.map { |c| c[:method_name] }
      expect(method_names).to include('transaction')
      expect(method_names).to include('lock!')
      expect(method_names).to include('create!')
    end

    it 'returns call hashes with required keys' do
      root = parser.parse("User.find(1)")
      calls = extractor.extract(root)

      expect(calls.first).to include(
        receiver: a_value,
        method_name: a_value,
        arguments: an_instance_of(Array),
        line: an_instance_of(Integer),
        block: a_value
      )
    end
  end

  describe '#extract_significant' do
    it 'filters out insignificant methods' do
      source = <<~RUBY
        def process
          user = User.find(id)
          user.nil?
          user.present?
          user.to_s
          UserService.call(user)
        end
      RUBY

      root = parser.parse(source)
      calls = extractor.extract_significant(root)

      method_names = calls.map { |c| c[:method_name] }
      expect(method_names).to include('find')
      expect(method_names).to include('call')
      expect(method_names).not_to include('nil?')
      expect(method_names).not_to include('present?')
      expect(method_names).not_to include('to_s')
    end

    it 'keeps insignificant methods when receiver is a known unit' do
      source = "MyService.new"

      root = parser.parse(source)
      calls = extractor.extract_significant(root, known_units: ['MyService'])

      method_names = calls.map { |c| c[:method_name] }
      expect(method_names).to include('new')
    end
  end
end
