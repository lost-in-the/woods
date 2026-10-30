# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/extractors/test_request_host'
require 'woods/extractors/test_mapping_extractor'

RSpec.describe Woods::Extractors::TestRequestHost do
  describe '.subdomains' do
    { "'admin'" => 'admin', '"admin"' => 'admin', ':admin' => 'admin', "''" => '', '""' => '' }.each do |literal, host|
      it "preserves the scanner capture for request option #{literal}" do
        source = "create(:account, subdomain: 'record')\nget '/settings', subdomain: #{literal}"

        expect(described_class.subdomains(source)).to eq([host])
        expect(described_class.literal_subdomains(source)).to eq([host])
      end

      it "preserves the scanner capture for possible returned option #{literal}" do
        source = "root_url(**attributes_for(:url, subdomain: #{literal}).except(runtime_key))"

        expect(described_class.subdomains(source)).to be_nil
        expect(described_class.literal_subdomains(source)).to eq([host])
      end
    end

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

    {
      'factory create' => "create(:account,\n  subdomain: 'app')",
      'factory build without parentheses' => "FactoryBot.build :account,\n  subdomain: 'app'",
      'factory create_list' => "create_list(:account, 2,\n  subdomain: 'app')",
      'factory build_list' => "build_list(:account, 2,\n  subdomain: 'app')",
      'factory build_stubbed' => "build_stubbed(:account,\n  subdomain: :app)",
      'factory attributes_for with a hash rocket' => "attributes_for(:account,\n  :subdomain => 'app')",
      'model create' => "Account.create(\n  subdomain: 'app')",
      'model create! with an explicit hash' => "Account.create!(\n  { :subdomain => :app })",
      'model new' => "Account.new(\n  subdomain: 'app')",
      'model find_by' => "Account.find_by(\n  subdomain: 'app')",
      'model where' => "Account.where(\n  subdomain: 'app')"
    }.each do |kind, record_call|
      it "does not read a multiline #{kind} attribute as a host" do
        source = "host! 'shop.example.test'\n#{record_call}\n"

        expect(described_class.subdomains(source)).to eq(['shop'])
      end
    end

    ["Account.find_by!(subdomain: 'admin')", "Account.find_by!(\n  subdomain: 'admin')"].each do |record_call|
      it "does not read find_by! record attributes in #{record_call.inspect} as hosts" do
        expect(described_class.subdomains("host! 'shop.example.test'\n#{record_call}")).to eq(['shop'])
      end
    end

    it 'does not read nested record attribute hashes or arrays as hosts' do
      source = <<~RUBY
        host! 'shop.example.test'
        FactoryBot.build(:account, {
          preferences: {
            tenants: [{ subdomain: 'app' }, { :subdomain => :admin }]
          }
        })
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    {
      'merge receiver' => "create(:account, { subdomain: 'admin' }.merge(name: 'A'))",
      'merge arguments' => "create(:account, { name: 'A' }.merge(subdomain: 'admin'))",
      'nested merge' => "Account.new({ name: 'A' }.merge({ subdomain: 'admin' }.merge(active: true)))",
      'Rails merge variants' => "Account.new({ subdomain: 'admin' }.deep_merge(name: 'A').reverse_merge(active: true))",
      'hash selection and key transforms' => "build(:account, { subdomain: 'admin' }.except(:name).symbolize_keys)",
      'compact receiver' => "create(:account, **{ subdomain: 'admin' }.compact)",
      'dup receiver' => "Account.new(\n  **{ subdomain: 'admin' }.dup)"
    }.each do |kind, record_call|
      it "keeps record attribute context through #{kind}" do
        source = "host! 'shop.example.test'\n#{record_call}\n"

        expect(described_class.subdomains(source)).to eq(['shop'])
      end
    end

    it 'keeps executable URL and request options inside record hash transforms' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, { subdomain: 'admin' }.merge(homepage: root_url(subdomain: 'link')))
        Account.new({ name: 'A' }.merge(subdomain: 'admin')) do
          get '/settings', subdomain: 'request'
        end
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link', 'request')
    end

    it 'keeps receiver data separate from executable method arguments and blocks' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, { subdomain: 'admin' }.decorate(root_url(subdomain: 'argument')))
        Account.new({ subdomain: 'admin', homepage: root_url(subdomain: 'link') }.compact.dup) do
          get '/settings', subdomain: 'request'
        end
        create(:account, { subdomain: 'admin' }.tap { visit root_url(subdomain: 'block') })
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'argument', 'link', 'request', 'block')
    end

    it 'does not read option text in record attribute strings as a host' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, description: "subdomain: 'admin'")
        Account.new(description: %q{subdomain: 'app'})
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
      expect(described_class.specifies_host?(%(create(:account, description: "subdomain: 'admin'"))))
        .to be(false)
    end

    it 'does not let interpolated option text in a record string make the host unknown' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: "subdomain: '#{tenant.name}'")
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'does not read record string receiver text as host options' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, description: "subdomain: 'admin'".strip)
        Account.new(description: (%q{subdomain: 'app'}).strip.upcase)
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'keeps executable interpolation separate from record string receiver text' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: "subdomain: '#{tenant.name}'".strip)
        Account.new(description: "subdomain: '#{root_url(subdomain: 'link')}'".strip.upcase)
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link')
    end

    it 'keeps dynamic executable host options in string receivers unknown' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: "#{root_url(subdomain: "#{tenant.name}")}".strip)
      RUBY

      expect(described_class.subdomains(source)).to be_nil
    end

    {
      'regexp' => "/subdomain: 'admin'/",
      'percent regexp' => "%r{subdomain: 'admin'}",
      'symbol array' => '%i[subdomain: :admin]',
      'quoted symbol' => %q(:"subdomain: 'admin'")
    }.each do |kind, literal|
      it "does not read record-owned #{kind} text as host options" do
        source = "host! 'shop.example.test'\ncreate(:account, name: 'Café 日本語', value: #{literal})"

        expect(described_class.subdomains(source)).to eq(['shop'])
        expect(described_class.specifies_host?("create(:account, value: #{literal})")).to be(false)
      end
    end

    it 'keeps executable interpolation and byte offsets in record regexps and symbols' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, name: 'Café 日本語', matcher: /subdomain: '#{tenant.name}'/)
        Account.new(matcher: %r{subdomain: '#{root_url(subdomain: 'été')}'})
        build(:account, label: :"subdomain: '#{root_url(subdomain: 'symbol')}'")
        create(:account, tokens: %I[subdomain: '#{tenant.name}'])
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'été', 'symbol')
    end

    it 'keeps executable URL options inside interpolated record strings' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: "subdomain: 'admin'; #{root_url(subdomain: 'link')}")
        Account.new(description: <<~TEXT)
          subdomain: 'app'; #{root_url(subdomain: 'heredoc')}
        TEXT
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link', 'heredoc')
    end

    it 'does not consume executable URL options while skipping interpolated record text' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: "subdomain: '#{root_url(subdomain: 'link')}'")
        Account.new(subdomain: "#{root_url(subdomain: 'attribute')}")
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link', 'attribute')
    end

    it 'keeps interpolated executable host options inside record strings unknown' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: "subdomain: '#{root_url(subdomain: "#{tenant.name}")}'")
      RUBY

      expect(described_class.subdomains(source)).to be_nil
    end

    it 'keeps Unicode word boundaries when another record option activates host scanning' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, subdomain: 'app', テナントsubdomain: 'admin', ésubdomain: 'other')
        visit root_url(subdomain: 'été')
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'été')
    end

    {
      'keyword URL options' => "visit root_url(**attributes_for(:account, subdomain: 'admin'))",
      'positional URL options' => "visit root_url(FactoryBot.attributes_for(:account, subdomain: 'admin'))",
      'keyword request options' => "get '/settings', **attributes_for(:account, subdomain: 'admin')",
      'positional request options' => "get '/settings', attributes_for(:account, subdomain: 'admin')",
      'explicit URL hash options' => "visit root_url({ **attributes_for(:account, subdomain: 'admin') })",
      'transformed URL options' => "visit root_url(**attributes_for(:account, subdomain: 'admin').merge(name: 'A'))",
      'compacted URL options' => "visit root_url(**attributes_for(:url, subdomain: 'admin').compact)",
      'duplicated request options' => "get '/settings', **attributes_for(:request, subdomain: 'admin').dup"
    }.each do |kind, request|
      it "reads a direct attributes_for result used as #{kind}" do
        expect(described_class.subdomains(request)).to eq(['admin'])
        expect(described_class.specifies_host?(request)).to be(true)
      end
    end

    it 'reads only immediate host options in a direct attributes_for result' do
      source = <<~RUBY
        root_url(**attributes_for(:request, subdomain: 'shop',
                                 params: { subdomain: 'admin' }, tenants: [{ subdomain: 'record' }]))
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    {
      'except(:subdomain)' => ['shop'],
      'except!(:subdomain)' => ['shop'],
      'slice(:locale)' => ['shop'],
      'slice(:subdomain)' => %w[shop admin],
      'except("subdomain")' => %w[shop admin],
      "merge(subdomain: 'shop')" => ['shop'],
      "merge!(subdomain: 'shop')" => ['shop'],
      "deep_merge(subdomain: 'shop')" => ['shop'],
      "reverse_merge(subdomain: 'fallback')" => %w[shop admin],
      "reverse_merge!(subdomain: 'fallback')" => %w[shop admin],
      "merge(runtime_options).merge(subdomain: 'final')" => %w[shop final],
      'except(runtime_key).except(:subdomain)' => ['shop']
    }.each do |transform, expected|
      it "respects the immediate returned host after #{transform}" do
        source = "host! 'shop.example.test'\nroot_url(**attributes_for(:url, subdomain: 'admin').#{transform})"

        expect(described_class.subdomains(source)).to eq(expected)
        expect(described_class.literal_subdomains(source)).to eq(expected)
      end
    end

    {
      'customize' => %w[shop admin],
      'merge(runtime_options)' => %w[shop admin],
      'reverse_merge(runtime_options)' => %w[shop admin],
      'reverse_merge!(runtime_options)' => %w[shop admin],
      'except(runtime_key)' => %w[shop admin],
      'slice(runtime_key)' => %w[shop admin],
      'slice!(:subdomain)' => %w[shop admin],
      'stringify_keys' => %w[shop admin],
      'compact!' => %w[shop admin],
      'tap { |opts| opts.delete(:subdomain) }' => %w[shop admin],
      "merge(subdomain: 'other') { |key, old, value| value }" => %w[shop admin other]
    }.each do |transform, possible|
      it "does not claim a literal returned host through unresolved #{transform}" do
        source = "host! 'shop.example.test'\nroot_url(**attributes_for(:url, subdomain: 'admin').#{transform})"

        expect(described_class.subdomains(source)).to be_nil
        expect(described_class.literal_subdomains(source)).to eq(possible)
        expect(described_class.specifies_host?(source)).to be(true)
      end
    end

    [
      "merge(subdomain: 'admin').except('subdomain')",
      "merge(subdomain: 'admin').slice('subdomain')",
      "merge('subdomain' => 'shop')",
      "merge(subdomain: 'other').except(:subdomain)"
    ].each do |transform|
      it "keeps opaque key semantics uncertain after #{transform}" do
        source = "host! 'shop.example.test'\n" \
                 "root_url(**attributes_for(:url, subdomain: 'admin').with_indifferent_access.#{transform})"

        expect(described_class.subdomains(source)).to be_nil
        expect(described_class.literal_subdomains(source)).to include('shop', 'admin')
      end
    end

    %w[except except!].each do |removal|
      {
        "slice('subdomain').#{removal}('subdomain')" => [%w[shop], %w[shop]],
        "#{removal}(:subdomain, 'subdomain')" => [%w[shop], %w[shop]],
        "slice('subdomain').#{removal}(:subdomain)" => [nil, %w[shop admin]],
        "slice(:subdomain).#{removal}('subdomain')" => [nil, %w[shop admin]],
        "slice('subdomain').#{removal}(runtime_key)" => [nil, %w[shop admin]]
      }.each do |transform, (expected, possible)|
        it "composes plain string and symbol selection with #{transform}" do
          source = "host! 'shop.example.test'\n" \
                   "root_url(**{ **attributes_for(:url, subdomain: 'admin').stringify_keys }.#{transform})"

          expect(described_class.subdomains(source)).to eq(expected)
          expect(described_class.literal_subdomains(source)).to eq(possible)
        end
      end
    end

    context 'with composed returned field writes and selections' do
      copied = "{ **attributes_for(:url, subdomain: 'admin').customize }"
      string = "#{copied}.slice('subdomain')"
      symbol = "#{copied}.slice(:subdomain)"
      write = "{ 'subdomain' => 'shop' }"
      {
        'a definite string write' => ["#{string}.merge('subdomain' => 'shop')", nil, %w[shop]],
        'a nested write then unknown operand' => ["#{string}.merge(#{write}.merge(runtime_options))", nil, %w[shop]],
        'a nested symbolic write then unknown operand' => [
          "#{symbol}.merge({ subdomain: 'shop' }.merge(runtime_options))", nil, %w[shop]
        ],
        'a flat write, unknown operand and final write' => [
          "#{string}.merge(#{write}, runtime_options, #{write})", nil, %w[shop]
        ],
        'an opposite-key write and removal' => [
          "#{copied}.merge('subdomain' => 'shop').except('subdomain')", nil, %w[shop admin]
        ],
        'a dynamic overwrite key' => ["#{string}.merge(runtime_key => 'shop')", nil, %w[shop admin]],
        'a nullable replacement compacted before merging' => [
          "#{string}.merge({ 'subdomain' => runtime_value }.compact)", nil, %w[shop admin]
        ],
        'non-nil alternative writes compacted before merging' => [
          "#{string}.merge(#{write}.merge({ 'subdomain' => 'other' }.except(runtime_key)).compact)", nil, %w[shop]
        ],
        'all-nil alternative writes compacted before merging' => [
          "attributes_for(:url, subdomain: 'admin')" \
          '.merge({ subdomain: nil }.merge({ subdomain: nil }.except(runtime_key)).compact)',
          %w[shop admin], %w[shop admin]
        ],
        'a non-nil interpolated replacement' => [
          "#{string}.merge({ 'subdomain' => \"\#{runtime_value}\" }.compact)", nil, %w[shop]
        ],
        'a final string nil write followed by compact' => [
          "#{string}.merge('subdomain' => nil).compact", %w[shop], %w[shop]
        ],
        'symbolic nil removal independent of string possibilities' => [
          "#{copied}.merge(subdomain: nil).compact.slice(:subdomain)", %w[shop], %w[shop]
        ],
        'string possibilities independent of symbolic nil removal' => [
          "#{copied}.merge(subdomain: nil).compact.slice('subdomain')", nil, %w[shop admin]
        ],
        'a definite removal beside a dynamic selector' => [
          "#{copied}.except(:subdomain, runtime_key).slice(:subdomain)", %w[shop], %w[shop]
        ],
        'a string selection beside a dynamic selector' => [
          "#{copied}.slice('subdomain', runtime_key).except('subdomain')", nil, %w[shop admin]
        ],
        'removal of both keys after mixed selectors' => [
          "#{copied}.slice(:subdomain, 'subdomain', runtime_key).except(:subdomain, 'subdomain')", %w[shop], %w[shop]
        ],
        'removal of both keys after a nested guaranteed write' => [
          "#{string}.merge(#{write}.merge(runtime_options)).except(:subdomain, 'subdomain')", %w[shop], %w[shop]
        ]
      }.each do |behavior, (expression, known, hints)|
        it "preserves host precision for #{behavior}" do
          source = "host! 'shop.example.test'\nroot_url(**#{expression})"

          expect(Prism.parse(source).errors).to eq([])
          expect(described_class.subdomains(source)).to eq(known)
          expect(described_class.literal_subdomains(source)).to eq(hints)
        end
      end

      it 'retains a symbolic possibility when the string key is overwritten and removed' do
        source = "host! 'shop.example.test'\n" \
                 "root_url(**#{symbol}.merge('subdomain' => 'shop').except('subdomain'))"

        expect(described_class.subdomains(source)).to be_nil
        expect(described_class.literal_subdomains(source)).to eq(%w[shop admin])
      end
    end

    it 'clears possible hosts only on a definite plain hash overwrite or removal' do
      prefix = "host! 'shop.example.test'\nroot_url(**attributes_for(:url, subdomain: 'admin').except(runtime_key)"

      expect(described_class.literal_subdomains("#{prefix}.except(:subdomain))")).to eq(['shop'])
      expect(described_class.literal_subdomains("#{prefix}.merge(subdomain: 'final'))")).to eq(%w[shop final])
    end

    it 'preserves opaque key semantics through parentheses and receiver chains' do
      source = <<~RUBY
        host! 'shop.example.test'
        root_url(**(attributes_for(:url, subdomain: 'admin').with_indifferent_access).dup
          .merge(subdomain: 'admin').except('subdomain'))
      RUBY

      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to eq(%w[shop admin])
    end

    [
      '.except(:subdomain)',
      '.except!(:subdomain)',
      ".merge(subdomain: 'other')",
      ".merge(subdomain: 'other').except(:subdomain)",
      ".merge(subdomain: 'other').except(runtime_key).except(:subdomain)",
      ".dup.merge(subdomain: 'other').except(:subdomain)"
    ].each do |transform|
      it "retains unresolved copied key identity after #{transform}" do
        source = "host! 'shop.example.test'\n" \
                 "root_url(**{ **attributes_for(:url, subdomain: 'admin').stringify_keys }#{transform})"

        expect(described_class.subdomains(source)).to be_nil
        expected = transform.end_with?("merge(subdomain: 'other')") ? %w[shop admin other] : %w[shop admin]
        expect(described_class.literal_subdomains(source)).to eq(expected)
      end
    end

    {
      '.except(:subdomain)' => ['shop'],
      ".merge(subdomain: 'final')" => %w[shop final],
      ".merge(subdomain: 'other').except(:subdomain)" => ['shop']
    }.each do |transform, expected|
      it "clears known copied symbolic keys after #{transform}" do
        source = "host! 'shop.example.test'\n" \
                 "root_url(**{ **attributes_for(:url, subdomain: 'admin').except(runtime_key) }#{transform})"

        expect(described_class.subdomains(source)).to eq(expected)
        expect(described_class.literal_subdomains(source)).to eq(expected)
      end
    end

    it 'respects explicit overwrite order around a returned hash splat' do
      source = <<~RUBY
        root_url(**attributes_for(:url, subdomain: 'old'), subdomain: 'last')
        get '/settings', subdomain: 'discarded', **attributes_for(:url, subdomain: 'returned')
      RUBY

      expect(described_class.subdomains(source)).to eq(%w[last returned])
    end

    %w[reverse_merge reverse_merge!].each do |merge|
      ['', '.except(:subdomain)', ".except('subdomain')"].each do |selection|
        it "keeps receiver key identity uncertain through opaque fallback #{merge}#{selection}" do
          source = <<~RUBY
            host! 'shop.example.test'
            root_url(**attributes_for(
              :url,
              subdomain: 'admin'
            ).#{merge}({ locale: 'en' }.with_indifferent_access)#{selection})
          RUBY

          expect(described_class.subdomains(source)).to be_nil
          expect(described_class.literal_subdomains(source)).to eq(%w[shop admin])
        end
      end

      {
        'slice(:locale)' => [%w[shop], %w[shop]],
        "slice('locale')" => [%w[shop], %w[shop]],
        'slice(:subdomain)' => [%w[shop], %w[shop]],
        'except(:subdomain).slice(:subdomain)' => [%w[shop], %w[shop]],
        'slice(:subdomain).except(:subdomain)' => [%w[shop], %w[shop]],
        "slice('subdomain')" => [nil, %w[shop admin]],
        "slice(:subdomain, 'subdomain')" => [nil, %w[shop admin]],
        'slice(runtime_key)' => [nil, %w[shop admin]],
        'slice(:locale, runtime_key)' => [nil, %w[shop admin]],
        'except(runtime_key).slice(:subdomain)' => [nil, %w[shop]],
        'except(:subdomain)' => [nil, %w[shop admin]]
      }.each do |selection, (hosts, hints)|
        it "selects only possible host keys through plain fallback #{merge}.#{selection}" do
          source = <<~RUBY
            host! 'shop.example.test'
            root_url(**attributes_for(:url, subdomain: 'shop').#{merge}({
              **attributes_for(:url, subdomain: 'admin').stringify_keys
            }).#{selection})
          RUBY

          expect(described_class.subdomains(source)).to eq(hosts)
          expect(described_class.literal_subdomains(source)).to eq(hints)
        end
      end

      ['', '.except(:subdomain)'].each do |removal|
        it "retains unresolved fallback key identity through #{merge}#{removal}" do
          source = <<~RUBY
            host! 'shop.example.test'
            root_url(**attributes_for(:url, subdomain: 'shop').#{merge}({
              **attributes_for(:url, subdomain: 'admin').stringify_keys
            })#{removal})
          RUBY

          expect(described_class.subdomains(source)).to be_nil
          expect(described_class.literal_subdomains(source)).to eq(%w[shop admin])
        end

        it "supersedes a known symbolic fallback through #{merge}#{removal}" do
          source = <<~RUBY
            host! 'shop.example.test'
            root_url(**attributes_for(:url, subdomain: 'shop').#{merge}({
              **attributes_for(:url, subdomain: 'admin')
            })#{removal})
          RUBY

          expect(described_class.subdomains(source)).to eq(['shop'])
          expect(described_class.literal_subdomains(source)).to eq(['shop'])
        end
      end
    end

    {
      'slice(:subdomain)' => [nil, %w[shop admin]],
      'slice(:locale)' => [%w[shop], %w[shop]],
      'except(:subdomain).slice(:subdomain)' => [%w[shop], %w[shop]],
      "merge(subdomain: 'final').slice(:subdomain)" => [%w[shop final], %w[shop final]],
      "merge(subdomain: 'final').except(runtime_key).slice(:subdomain)" => [nil, %w[shop final]]
    }.each do |selection, (hosts, hints)|
      it "preserves independent symbolic possibilities in an opaque copy after #{selection}" do
        source = "host! 'shop.example.test'\n" \
                 "root_url(**{ **attributes_for(:url, subdomain: 'admin').customize }.#{selection})"

        expect(described_class.subdomains(source)).to eq(hosts)
        expect(described_class.literal_subdomains(source)).to eq(hints)
      end
    end

    it 'does not infer factory defaults to establish reverse merge precedence' do
      source = "root_url(**attributes_for(:url).reverse_merge(subdomain: 'fallback'))"

      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to eq(['fallback'])
    end

    it 'does not treat an unspecified factory default as a new host hint' do
      source = "host! 'shop.example.test'\nroot_url(**attributes_for(:url))"

      expect(described_class.subdomains(source)).to eq(['shop'])
      expect(described_class.subdomains("#{source}\ncreate(:account, subdomain: 'record')")).to eq(['shop'])
    end

    it 'limits returned-field uncertainty to expressions with a named symbolic host field' do
      source = "host! 'shop.example.test'\nroot_url(**attributes_for(:url).merge(runtime_options))"

      # Unnamed runtime options are an existing limit, including when an
      # unrelated record attribute bypasses the no-OPTION_KEY fast path.
      expect(described_class.subdomains(source)).to eq(['shop'])
      expect(described_class.subdomains("#{source}\ncreate(:account, subdomain: 'record')")).to eq(['shop'])
    end

    it 'keeps a directly supplied nonliteral host unknown without following its value' do
      source = "host! 'shop.example.test'\nroot_url(**attributes_for(:url, subdomain: tenant.name))"

      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to eq(['shop'])
    end

    it 'keeps nested executable interpolation visible when the returned host itself is unknown' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        root_url(**attributes_for(:url, subdomain: "#{root_url(subdomain: 'link')}"))
      RUBY

      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to eq(%w[shop link])
    end

    it 'visits executable calls even in removed fields and transformed returned record values' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        root_url(**attributes_for(:url, subdomain: "#{root_url(subdomain: 'link')}").except(:subdomain))
        root_url(**attributes_for(:url, subdomain: 'shop').merge(
          description: normalize("subdomain: '#{root_url(subdomain: 'nested')}'"),
          params: { subdomain: 'record' }))
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link', 'nested')
    end

    {
      'string' => %q("subdomain: 'admin'"),
      'regexp' => "/subdomain: 'admin'/",
      'symbol' => %q(:"subdomain: 'admin'"),
      'symbol array' => '%i[subdomain: :admin]',
      'backtick command' => %q(`printf "subdomain: 'admin'"`),
      'percent command' => %q(%x{printf "subdomain: 'admin'"})
    }.each do |kind, literal|
      it "keeps record-owned #{kind} text excluded through ordinary call arguments" do
        source = "create(:account, description: normalize(wrap(#{literal})))"

        expect(described_class.subdomains("host! 'shop.example.test'\n#{source}")).to eq(['shop'])
        expect(described_class.specifies_host?(source)).to be(false)
      end
    end

    [%q(`printf "subdomain: 'admin'"`), %q(%x{printf "subdomain: 'admin'"})].each do |literal|
      it "excludes static command text in #{literal.inspect} without executing it" do
        source = "host! 'shop.example.test'\ncreate(:account, name: 'Café 日本語', description: #{literal})"

        expect(described_class.subdomains(source)).to eq(['shop'])
      end
    end

    it 'separates wrapped literal text from interpolation, executable arguments and blocks' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account, description: normalize("subdomain: '#{root_url(subdomain: 'link')}'"))
        create(:account, matcher: normalize(/subdomain: '#{root_url(subdomain: 'regexp')}'/))
        create(:account, label: normalize(:"subdomain: '#{root_url(subdomain: 'symbol')}'"))
        create(:account, description: normalize("subdomain: '#{tenant.name}'", root_url(subdomain: 'argument')))
        create(:account, description: normalize("subdomain: 'admin'") { get '/x', subdomain: 'block' })
        create(:account, name: 'Café 日本語', command: `printf "subdomain: '#{root_url(subdomain: 'été')}'"`)
        create(:account, command: normalize(%x{printf "subdomain: '#{root_url(subdomain: 'command')}'"}))
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly(
        'shop', 'link', 'regexp', 'symbol', 'argument', 'block', 'été', 'command'
      )
    end

    it 'keeps returned attributes_for field text separate from executable nested options' do
      source = <<~'RUBY'
        root_url(**attributes_for(:request, subdomain: 'shop',
                                 description: "subdomain: '#{tenant.name}'".strip,
                                 pattern: /subdomain: 'admin'/,
                                 params: { subdomain: 'record', homepage: root_url(subdomain: 'link') },
                                 label: "#{url_for(subdomain: 'interpolated')}"))
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link', 'interpolated')
    end

    it 'keeps immediate dynamic attributes_for host options unknown' do
      source = <<~'RUBY'
        root_url(**attributes_for(:request, subdomain: "#{tenant.name}", params: { subdomain: 'admin' }))
      RUBY

      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to eq([])
    end

    it 'keeps record params separate from direct request host options' do
      source = <<~RUBY
        get '/settings', params: attributes_for(:account, subdomain: 'record'),
                         **attributes_for(:request, subdomain: 'admin')
      RUBY

      expect(described_class.subdomains(source)).to eq(['admin'])
    end

    it 'does not follow attributes_for results through record params or arbitrary helper calls' do
      source = <<~RUBY
        host! 'shop.example.test'
        get '/settings', params: attributes_for(:account, subdomain: 'record')
        visit root_url(**decorate(attributes_for(:account, subdomain: 'wrapped')))
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'keeps direct URL options when the URL call itself supplies a record attribute' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, subdomain: 'record', homepage: root_url(**attributes_for(:url, subdomain: 'link')))
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link')
    end

    it 'uses argument context even when the record call starts many lines earlier' do
      source = "host! 'shop.example.test'\ncreate(:account,\n#{"  # attribute note\n" * 64}  subdomain: 'app')"

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'keeps host options inside nested url calls and record blocks or after a completed call' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account, homepage: root_url(subdomain: 'link'))
        create(:account) do
          visit root_url(
            subdomain: 'block'
          )
        end
        Account.new; get '/settings', subdomain: 'request'
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'link', 'block', 'request')
    end

    it 'preserves host calls and request header hosts beside multiline attributes' do
      source = <<~RUBY
        host! 'shop.example.test'
        create(:account,
          subdomain: 'app'
        ) do
          host! 'admin.example.test'
          get '/settings', headers: { 'HTTP_HOST' => 'api.example.test' }
        end
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'admin', 'api')
    end

    it 'matches syntax byte offsets while preserving UTF-8 option values' do
      source = <<~RUBY
        host! 'shop.example.test'
        name = 'Café 日本語 ☕'
        Account.new(
          name: name,
          subdomain: 'app'
        )
        visit root_url(subdomain: 'été')
      RUBY

      expect(described_class.subdomains(source)).to contain_exactly('shop', 'été')
    end

    it 'preserves source encoding through literal receivers and returned record fields' do
      source = <<~RUBY.encode(Encoding::ISO_8859_1)
        # encoding: ISO-8859-1
        host! 'shop.example.test'
        create(:account, description: "Café subdomain: 'admin'".strip)
        root_url(**attributes_for(:request, subdomain: 'été', params: { subdomain: 'record' }).compact)
      RUBY

      hosts = described_class.subdomains(source)

      expect(hosts).to eq(['shop', 'été'.encode(Encoding::ISO_8859_1)])
      expect(hosts.last.encoding).to eq(Encoding::ISO_8859_1)
    end

    it 'preserves non-UTF-8 offsets through wrapped command text and returned host selection' do
      source = <<~RUBY.encode(Encoding::ISO_8859_1)
        # encoding: ISO-8859-1
        host! 'shop.example.test'
        create(:account, description: normalize(`printf "Café subdomain: 'admin'"`))
        root_url(**attributes_for(:url, subdomain: 'admin').merge(subdomain: 'été'))
      RUBY

      hosts = described_class.subdomains(source)

      expect(hosts).to eq(['shop', 'été'.encode(Encoding::ISO_8859_1)])
      expect(hosts.last.encoding).to eq(Encoding::ISO_8859_1)
    end

    [
      %q{create(:account, description: normalize("subdomain: 'admin'")},
      %q{create(:account, description: `printf "subdomain: 'admin'"`},
      "root_url(**attributes_for(:url, subdomain: 'admin').except(:subdomain)"
    ].each do |incomplete|
      it "keeps recovered record ownership in incomplete source #{incomplete.inspect}" do
        expect(described_class.subdomains("host! 'shop.example.test'\n#{incomplete}")).to eq(['shop'])
      end
    end

    it 'preserves byte offsets in binary source containing an invalid UTF-8 byte' do
      source = "host! 'shop.example.test'\n# \xFF\n".b +
               %q(create(:account, description: normalize(`printf "subdomain: 'admin'"`))).b

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'handles incomplete record source without losing a known request host' do
      source = "host! 'shop.example.test'\nAccount.find_by!(\n  subdomain: 'admin'"

      expect(described_class.subdomains(source)).to eq(['shop'])
    end

    it 'does not let an interpolated record attribute make the request host unknown' do
      source = <<~'RUBY'
        host! 'shop.example.test'
        create(:account,
          subdomain: "#{tenant.subdomain}"
        )
      RUBY

      expect(described_class.subdomains(source)).to eq(['shop'])
      expect(described_class.subdomains("#{source}\nget '/settings', subdomain: \"\#{tenant.subdomain}\""))
        .to be_nil
    end

    it 'does not specify any request host when only a multiline record attribute names one' do
      source = "create(:account,\n  subdomain: 'app')"

      expect(described_class.specifies_host?(source)).to be(false)
      expect(described_class.subdomains(source)).to be_nil
      expect(described_class.literal_subdomains(source)).to eq([])
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

  describe 'route edges from multiline record attributes' do
    include_context 'extractor setup'

    context 'with removed selected string keys' do
      [[], %w[shop api]].each do |controller_hosts|
        %w[except except!].each do |removal|
          it "does not retain an admin redirect after #{removal} beside #{controller_hosts.inspect}" do
            stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
            redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                    constraints: { subdomain: 'admin' })
            allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
            controllers = controller_hosts.map do |subdomain|
              route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                           constraints: { subdomain: subdomain })
            end
            stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
            options = "{ **attributes_for(:url, subdomain: 'admin').stringify_keys }"
            source = <<~RUBY
              host! 'shop.example.test'
              get url_for(controller: 'settings', action: 'show', **#{options}.slice('subdomain').#{removal}('subdomain'))
              get '/settings'
            RUBY
            path = create_file('spec/requests/settings_spec.rb', source)
            unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

            aggregate_failures do
              expect(Woods::Extractors::TestRequestHost.subdomains(source)).to eq(['shop'])
              expect(Woods::Extractors::TestRequestHost.literal_subdomains(source)).to eq(['shop'])
              expected = if controller_hosts.any?
                           [{ type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }]
                         else
                           []
                         end
              expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(expected)
              expect(unit.metadata[:routes_ambiguous]).to eq([])
            end
          end
        end
      end
    end

    context 'with independently selected returned keys' do
      [[], %w[shop api]].each do |controller_hosts|
        context "beside #{controller_hosts.inspect} controller routes" do
          before do
            stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
            redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                    constraints: { subdomain: 'admin' })
            allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
            controllers = controller_hosts.map do |subdomain|
              route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                           constraints: { subdomain: subdomain })
            end
            stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
          end

          %w[reverse_merge reverse_merge!].each do |merge|
            opaque = "attributes_for(:url, subdomain: 'admin').#{merge}({ locale: 'en' }.with_indifferent_access)"
            copied = "attributes_for(:url, subdomain: 'shop').#{merge}({ " \
                     "**attributes_for(:url, subdomain: 'admin').stringify_keys })"
            known = "attributes_for(:url, subdomain: 'shop').#{merge}({ " \
                    "**attributes_for(:url, subdomain: 'admin') })"
            {
              'opaque fallback symbol removal' => ["#{opaque}.except(:subdomain)", true],
              'opaque fallback string removal' => ["#{opaque}.except('subdomain')", true],
              'plain unrelated slice' => ["#{copied}.slice(:locale)", false],
              'plain symbol slice' => ["#{copied}.slice(:subdomain)", false],
              'plain string slice' => ["#{copied}.slice('subdomain')", true],
              'plain dynamic slice' => ["#{copied}.slice(runtime_key)", true],
              'plain symbol removal' => ["#{copied}.except(:subdomain)", true],
              'known symbol fallback slice' => ["#{known}.slice(:subdomain)", false],
              'known symbol fallback removal' => ["#{known}.except(:subdomain)", false]
            }.each do |kind, (expression, uncertain)|
              it "resolves #{merge} #{kind} without stale or missing redirect hints" do
                path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
                  host! 'shop.example.test'
                  get url_for(controller: 'settings', action: 'show', **#{expression})
                  get '/settings'
                RUBY

                unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)
                edges = unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }

                if uncertain && controller_hosts.any?
                  expect(edges).to eq([])
                  expect(unit.metadata[:routes_ambiguous]).to eq(
                    [{ request: 'GET /settings',
                       candidates: ['GET /settings [subdomain=admin] (redirect)',
                                    'GET /settings [subdomain=api]', 'GET /settings [subdomain=shop]'] }]
                  )
                else
                  target = if uncertain
                             'GET /settings [subdomain=admin] (redirect)'
                           elsif controller_hosts.any?
                             'GET /settings [subdomain=shop]'
                           end
                  expected = target ? [{ type: :route, target: target, via: :exercises_route }] : []
                  expect(edges).to eq(expected)
                  expect(unit.metadata[:routes_ambiguous]).to eq([])
                end
              end
            end
          end
        end
      end
    end

    %w[reverse_merge reverse_merge!].each do |merge|
      [[], %w[shop api]].each do |controller_hosts|
        it "retains a #{merge} fallback redirect beside #{controller_hosts.inspect} controller routes" do
          stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
          redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                  constraints: { subdomain: 'admin' })
          allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
          controllers = controller_hosts.map do |subdomain|
            route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                         constraints: { subdomain: subdomain })
          end
          stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
          path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
            host! 'shop.example.test'
            get url_for(controller: 'settings', action: 'show', **attributes_for(
              :url, subdomain: 'shop'
            ).#{merge}({
              **attributes_for(
                :url,
                subdomain: 'admin'
              ).stringify_keys
            }).except(:subdomain))
            get '/settings'
          RUBY

          unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)
          edges = unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }

          if controller_hosts.empty?
            expect(edges).to eq(
              [{ type: :route, target: 'GET /settings [subdomain=admin] (redirect)', via: :exercises_route }]
            )
            expect(unit.metadata[:routes_ambiguous]).to eq([])
          else
            expect(edges).to eq([])
            expect(unit.metadata[:routes_ambiguous]).to eq(
              [{ request: 'GET /settings',
                 candidates: ['GET /settings [subdomain=admin] (redirect)',
                              'GET /settings [subdomain=api]', 'GET /settings [subdomain=shop]'] }]
            )
          end
        end
      end

      it "omits a superseded symbolic #{merge} fallback redirect" do
        stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
        redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                constraints: { subdomain: 'admin' })
        allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
        controllers = %w[shop api].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end
        stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
        path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
          host! 'shop.example.test'
          get url_for(controller: 'settings', action: 'show', **attributes_for(
            :url, subdomain: 'shop'
          ).#{merge}({ **attributes_for(:url, subdomain: 'admin') }).except(:subdomain))
          get '/settings'
        RUBY

        unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

        expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(
          [{ type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }]
        )
        expect(unit.metadata[:routes_ambiguous]).to eq([])
      end
    end

    { "'admin'" => 'admin', '"admin"' => 'admin', ':admin' => 'admin', "''" => '', '""' => '' }.each do |literal, host|
      it "keeps actual route edges for scanner option #{literal}" do
        stub_route_set(
          ['shop', host].map do |subdomain|
            route_double(verb: 'GET', path: '/settings', controller: 'settings', action: 'show',
                         constraints: { subdomain: subdomain })
          end,
          root: rails_root, logger: logger
        )
        path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
          host! 'shop.example.test'
          get '/settings', subdomain: #{literal}
        RUBY

        unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

        expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to contain_exactly(
          { type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route },
          { type: :route, target: "GET /settings [subdomain=#{host}]", via: :exercises_route }
        )
        expect(unit.metadata[:routes_ambiguous]).to eq([])
      end
    end

    [[], %w[shop api]].each do |controller_hosts|
      it "retains copied-key redirect reachability beside #{controller_hosts.inspect} controller routes" do
        stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
        redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                constraints: { subdomain: 'admin' })
        allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
        controllers = controller_hosts.map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end
        stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
        path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
          host! 'shop.example.test'
          get url_for(controller: 'settings', action: 'show', **{
            **attributes_for(
              :url,
              subdomain: 'admin'
            ).stringify_keys
          }.except(:subdomain))
          get '/settings'
        RUBY

        unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)
        edges = unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }

        if controller_hosts.empty?
          expect(edges).to eq(
            [{ type: :route, target: 'GET /settings [subdomain=admin] (redirect)', via: :exercises_route }]
          )
          expect(unit.metadata[:routes_ambiguous]).to eq([])
        else
          expect(edges).to eq([])
          expect(unit.metadata[:routes_ambiguous]).to eq(
            [{ request: 'GET /settings',
               candidates: ['GET /settings [subdomain=admin] (redirect)',
                            'GET /settings [subdomain=api]', 'GET /settings [subdomain=shop]'] }]
          )
        end
      end
    end

    [
      "merge(subdomain: 'admin').except('subdomain')",
      "merge(subdomain: 'admin').slice('subdomain')",
      "merge('subdomain' => 'shop')"
    ].each do |transform|
      it "keeps route choices ambiguous after opaque key semantics and #{transform}" do
        stub_route_set(
          %w[shop admin].map do |subdomain|
            route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                         constraints: { subdomain: subdomain })
          end,
          root: rails_root, logger: logger
        )
        source = "host! 'shop.example.test'\n" \
                 "root_url(**attributes_for(:url, subdomain: 'admin').with_indifferent_access.#{transform})\n" \
                 "get '/settings'"
        path = create_file('spec/requests/settings_spec.rb', source)

        unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

        expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq([])
        expect(unit.metadata[:routes_ambiguous]).to eq(
          [{ request: 'GET /settings',
             candidates: ['GET /settings [subdomain=admin]', 'GET /settings [subdomain=shop]'] }]
        )
      end
    end

    [[], %w[shop api]].each do |controller_hosts|
      it "retains a possible admin redirect beside #{controller_hosts.inspect} controller routes" do
        stub_const('ActionDispatch::Routing::Redirect', Struct.new(:block, :status))
        redirect = route_double(verb: 'GET', path: '/settings', controller: nil, action: nil,
                                constraints: { subdomain: 'admin' })
        allow(redirect).to receive(:app).and_return(ActionDispatch::Routing::Redirect.new('/profile', 302))
        controllers = controller_hosts.map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end
        stub_route_set([redirect, *controllers], root: rails_root, logger: logger)
        path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
          host! 'shop.example.test'
          root_url(**attributes_for(
            :url,
            subdomain: 'admin'
          ).except(runtime_key))
          get '/settings'
        RUBY

        unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)
        edges = unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }

        if controller_hosts.empty?
          expect(edges).to eq(
            [{ type: :route, target: 'GET /settings [subdomain=admin] (redirect)', via: :exercises_route }]
          )
          expect(unit.metadata[:routes_ambiguous]).to eq([])
        else
          expect(edges).to eq([])
          expect(unit.metadata[:routes_ambiguous]).to eq(
            [{ request: 'GET /settings',
               candidates: ['GET /settings [subdomain=admin] (redirect)',
                            'GET /settings [subdomain=api]', 'GET /settings [subdomain=shop]'] }]
          )
        end
      end
    end

    [
      "root_url(**attributes_for(:url, subdomain: 'admin').except(:subdomain))",
      "root_url(**attributes_for(:url, subdomain: 'admin').slice(:locale))",
      "root_url(**attributes_for(:url, subdomain: 'admin').merge(subdomain: 'shop'))",
      "root_url(**attributes_for(:url, subdomain: 'admin').merge!(subdomain: 'shop'))",
      "root_url(**{ **attributes_for(:url, subdomain: 'admin') }.except(:subdomain))",
      "root_url(**{ **attributes_for(:url, subdomain: 'admin') }.merge(subdomain: 'shop'))",
      %q(create(:account, description: normalize("subdomain: 'admin'"))),
      "create(:account, matcher: normalize(/subdomain: 'admin'/))",
      %q(create(:account, label: normalize(:"subdomain: 'admin'"))),
      %q(create(:account, description: `printf "subdomain: 'admin'"`)),
      %q(create(:account, description: %x{printf "subdomain: 'admin'"}))
    ].each do |expression|
      it "avoids false admin route edges for #{expression}" do
        stub_route_set(
          %w[shop admin].map do |subdomain|
            route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                         constraints: { subdomain: subdomain })
          end,
          root: rails_root, logger: logger
        )
        source = "host! 'shop.example.test'\n#{expression}\nget '/settings'"
        path = create_file('spec/requests/settings_spec.rb', source)

        unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

        expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(
          [{ type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }]
        )
        expect(unit.metadata[:routes_ambiguous]).to eq([])
      end
    end

    it 'keeps shop and interpolated link route edges beside wrapped record text and command text' do
      stub_route_set(
        %w[shop link admin].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end,
        root: rails_root, logger: logger
      )
      path = create_file('spec/requests/settings_spec.rb', <<~'RUBY')
        host! 'shop.example.test'
        create(:account, description: normalize("subdomain: '#{root_url(subdomain: 'link')}'"))
        create(:account, command: %x{printf "subdomain: '#{root_url(subdomain: 'link')}'"})
        get '/settings'
      RUBY

      unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

      expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to contain_exactly(
        { type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route },
        { type: :route, target: 'GET /settings [subdomain=link]', via: :exercises_route }
      )
      expect(unit.metadata[:routes_ambiguous]).to eq([])
    end

    it 'keeps unresolved returned transformations ambiguous instead of asserting a stale host edge' do
      stub_route_set(
        %w[shop admin].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end,
        root: rails_root, logger: logger
      )
      path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
        host! 'shop.example.test'
        root_url(**attributes_for(:url, subdomain: 'admin').merge(runtime_options))
        get '/settings'
      RUBY

      unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

      expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq([])
      expect(unit.metadata[:routes_ambiguous]).to eq(
        [{ request: 'GET /settings',
           candidates: ['GET /settings [subdomain=admin]', 'GET /settings [subdomain=shop]'] }]
      )
    end

    it 'does not add exercises_route edges for factory or model attribute subdomains' do
      stub_route_set(
        %w[shop app admin].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end,
        root: rails_root, logger: logger
      )
      path = create_file('spec/requests/settings_spec.rb', <<~RUBY)
        RSpec.describe 'Settings' do
          it 'shows settings' do
            host! 'shop.example.test'
            create(:account,
              subdomain: 'app'
            )
            Account.new({
              subdomain: 'admin'
            })
            get '/settings'
          end
        end
      RUBY

      unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

      expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(
        [{ type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }]
      )
    end

    it 'does not add route edges for transformed hashes, string text or Unicode key suffixes' do
      stub_route_set(
        %w[shop app admin].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end,
        root: rails_root, logger: logger
      )
      path = create_file('spec/requests/settings_spec.rb', <<~'RUBY')
        RSpec.describe 'Settings' do
          it 'shows settings' do
            host! 'shop.example.test'
            create(:account, { subdomain: 'admin' }.merge(name: 'A'))
            create(:account, description: "subdomain: '#{tenant.name}'")
            create(:account, subdomain: 'app', テナントsubdomain: 'admin')
            get '/settings'
          end
        end
      RUBY

      unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

      expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(
        [{ type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }]
      )
    end

    it 'keeps route edges scoped to the request host beside transformed and literal record values' do
      stub_route_set(
        [route_double(verb: 'GET', path: '/', name: 'root', controller: 'home', action: 'show')] +
        %w[shop admin].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end,
        root: rails_root, logger: logger
      )
      path = create_file('spec/requests/settings_spec.rb', <<~'RUBY')
        RSpec.describe 'Settings' do
          it 'shows settings' do
            host! 'shop.example.test'
            Account.find_by!(subdomain: 'admin')
            create(:account, **{ subdomain: 'admin' }.compact.dup)
            create(:account, description: "subdomain: '#{tenant.name}'".strip)
            create(:account, matcher: /subdomain: 'admin'/, tokens: %i[subdomain: :admin])
            visit root_url(**attributes_for(:request, subdomain: 'shop', params: { subdomain: 'admin' },
                                           description: "subdomain: '#{tenant.name}'").compact)
            get '/settings'
          end
        end
      RUBY

      unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

      expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(
        [{ type: :route, target: 'GET /', via: :exercises_route },
         { type: :route, target: 'GET /settings [subdomain=shop]', via: :exercises_route }]
      )
    end

    it 'uses direct attributes_for URL options for literal navigation before the Capybara default host' do
      stub_route_set(
        [route_double(verb: 'GET', path: '/', name: 'root', controller: 'home', action: 'show')] +
        %w[shop admin].map do |subdomain|
          route_double(verb: 'GET', path: '/settings', controller: "#{subdomain}/settings", action: 'show',
                       constraints: { subdomain: subdomain })
        end,
        root: rails_root, logger: logger
      )
      create_file('spec/support/capybara.rb', "Capybara.app_host = 'https://shop.example.test'")
      path = create_file('spec/features/settings_spec.rb', <<~RUBY)
        RSpec.describe 'Settings', type: :feature do
          it 'shows settings' do
            visit root_url(**attributes_for(:account, subdomain: 'admin'))
            visit '/settings'
          end
        end
      RUBY

      unit = Woods::Extractors::TestMappingExtractor.new.extract_test_file(path)

      expect(unit.dependencies.select { |dependency| dependency[:via] == :exercises_route }).to eq(
        [{ type: :route, target: 'GET /', via: :exercises_route },
         { type: :route, target: 'GET /settings [subdomain=admin]', via: :exercises_route }]
      )
    end
  end
end
