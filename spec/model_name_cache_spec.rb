# frozen_string_literal: true

require 'spec_helper'
require 'woods/model_name_cache'

RSpec.describe Woods::ModelNameCache do
  after do
    described_class.reset!
  end

  describe '.model_names' do
    it 'returns descendant names when ActiveRecord::Base is defined' do
      user_class = double('User', name: 'User')
      post_class = double('Post', name: 'Post')
      stub_const('ActiveRecord::Base', double('AR::Base', descendants: [user_class, post_class]))

      expect(described_class.model_names).to eq(%w[User Post])
    end

    it 'returns empty array when ActiveRecord::Base is not defined' do
      # ActiveRecord::Base is not defined in the spec environment
      expect(described_class.model_names).to eq([])
    end
  end

  describe '.model_names_regex' do
    it 'matches model names as whole words' do
      stub_const('ActiveRecord::Base', double('AR::Base', descendants: [double(name: 'User')]))

      regex = described_class.model_names_regex
      expect('User').to match(regex)
      expect('UserService').not_to match(regex)
      expect('AdminUser').not_to match(regex)
    end

    it 'escapes names with regex-special characters' do
      stub_const('ActiveRecord::Base', double('AR::Base', descendants: [double(name: 'App::V2.User')]))

      regex = described_class.model_names_regex
      expect('App::V2.User').to match(regex)
      # The dot should be literal, not match any character
      expect('App::V2XUser').not_to match(regex)
    end
  end

  describe '.reset!' do
    it 'clears memoized values so next call recomputes' do
      ar_base = double('AR::Base')
      stub_const('ActiveRecord::Base', ar_base)

      allow(ar_base).to receive(:descendants).and_return([double(name: 'User')])
      expect(described_class.model_names).to eq(%w[User])

      described_class.reset!

      # After reset, descendants returns a different set — proves recomputation
      allow(ar_base).to receive(:descendants).and_return([double(name: 'Order'), double(name: 'Product')])
      expect(described_class.model_names).to eq(%w[Order Product])
    end
  end
end
