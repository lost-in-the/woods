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

  describe '.resolve_short_name' do
    it 'resolves a bare inner class name to its fully-qualified owner' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [double(name: 'Library::Book')]))

      expect(described_class.resolve_short_name('Book')).to eq('Library::Book')
    end

    it 'returns nil for ambiguous short names (collision across namespaces)' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [
                          double(name: 'Library::Book'),
                          double(name: 'Catalog::Book')
                        ]))

      expect(described_class.resolve_short_name('Book')).to be_nil
    end

    it 'returns a top-level name as itself' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [double(name: 'User')]))

      expect(described_class.resolve_short_name('User')).to eq('User')
    end
  end

  describe '.short_names_regex' do
    it 'matches bare short names only when not preceded by :: or a word char' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [double(name: 'Library::Book')]))

      regex = described_class.short_names_regex
      expect('Book.new').to match(regex)
      expect(' Book.new').to match(regex)
      # preceded by :: — already handled by the full-name regex, avoid double-count
      expect('Library::Book.new').not_to match(regex)
      # preceded by word char — part of another identifier, not our match
      expect('RareBook.new').not_to match(regex)
    end

    it 'does not include names with no namespace (they already match the full regex)' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [double(name: 'User')]))

      # short name == full name, so nothing to add via short-names regex
      expect('User').not_to match(described_class.short_names_regex)
    end

    # False-positive guards — ghost edges from prose / string literals are
    # exactly what the tightened lookahead is meant to prevent.
    it 'does NOT match short names appearing in prose without a use-context' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [double(name: 'Library::Book')]))

      regex = described_class.short_names_regex
      # YARD / freeform comment context ("- rewrite Book later")
      expect('rewrite Book later').not_to match(regex)
      # Bare string literal with no follow-up method call
      expect('"Book"').not_to match(regex)
    end

    it 'matches short names used as class references in common Ruby forms' do
      stub_const('ActiveRecord::Base',
                 double('AR::Base', descendants: [double(name: 'Library::Book')]))

      regex = described_class.short_names_regex
      expect('Book.new(isbn: "x")').to match(regex)
      expect('Book::INNER_CONST').to match(regex)
      expect('scope.push(Book)').to match(regex)
      expect('method_returns_book = Book').to match(regex)
    end
  end
end
