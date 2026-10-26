# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/test_request_host'

RSpec.describe Woods::Extractors::TestRequestHost do
  describe '.subdomains' do
    it 'does not read translation keys or event names as hosts in a file that calls host!' do
      source = <<~RUBY
        host! "shop.example.test"
        expect(page).to have_content I18n.t("app.errors.x")
        expect(event.name).to eq "order.created"
        expect(flash[:notice]).to eq t("orders.index.title")
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'does not read a factory attribute named subdomain as a host' do
      source = <<~RUBY
        host! "shop.example.test"
        let(:account) { create(:account, subdomain: 'app') }
        let(:other) { FactoryBot.build(:account, :trial, subdomain: "other") }
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'still reads a subdomain option on a url helper or request' do
      expect(described_class.subdomains(%(visit root_url(subdomain: "shop")))).to eq(['shop'])
      expect(described_class.subdomains(%(get "/x", :subdomain => :shop))).to eq(['shop'])
    end

    it 'still reads literal hosts that host! takes from data' do
      source = "[{ host: 'my.example.test' }, { host: 'app.example.com' }].each { |s| host! s[:host] }"

      expect(described_class.subdomains(source)).to contain_exactly('my', 'app')
    end
  end
end
