# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/js_tokenizer'

RSpec.describe Woods::Extractors::JsTokenizer do
  def tokens(source)
    described_class.tokens(source)
  end

  def values(source)
    tokens(source).map(&:last)
  end

  it 'emits identifiers, strings and punctuation' do
    expect(tokens('import Widget from "./widget";')).to eq(
      [[:ident, 'import'], [:ident, 'Widget'], [:ident, 'from'], [:string, './widget'], [:punct, ';']]
    )
  end

  it 'skips line and block comments' do
    source = <<~JS
      // import Hidden from "./hidden"
      /* Alpine.data("ghost", () => ({}))
         still a comment */
      const a = 1 // trailing
    JS

    expect(values(source)).to eq(['const', 'a', '=', nil])
  end

  it 'keeps string contents out of the token stream' do
    expect(values(%q(const s = 'import X from "./x"';))).to eq(['const', 's', '=', 'import X from "./x"', ';'])
  end

  it 'ends an unterminated string at the line break' do
    expect(values("const s = 'broken\nexport default s")).to eq(%w[const s = broken export default s])
  end

  it 'honours escapes inside strings' do
    expect(values('x = "a\\"b"')).to eq(['x', '=', 'a\\"b'])
  end

  it 'reads a plain template literal as a string' do
    expect(tokens('import(`./lazy`)')).to eq(
      [[:ident, 'import'], [:punct, '('], [:string, './lazy'], [:punct, ')']]
    )
  end

  it 'tokenizes template interpolations and resumes the template after them' do
    source = 'const t = `a ${ fn({ b: `c ${d}` }) } "not a string`; export default t'

    expect(values(source)).to eq(
      ['const', 't', '=', nil, 'fn', '(', '{', 'b', ':', nil, 'd', nil, '}', ')', nil, ';', 'export', 'default', 't']
    )
  end

  it 'reads a regular expression literal as one value token, including quotes inside it' do
    expect(tokens(%q(const re = /["'`]\/[/]/g; export default re))).to eq(
      [[:ident, 'const'], [:ident, 're'], [:punct, '='], [:regex, nil], [:punct, ';'],
       [:ident, 'export'], [:ident, 'default'], [:ident, 're']]
    )
  end

  it 'reads a slash after a value as division' do
    expect(values('const half = total / 2 / count')).to eq(['const', 'half', '=', 'total', '/', nil, '/', 'count'])
  end

  it 'distinguishes assignment, comparison and arrows' do
    expect(values('a = b == c === d => e')).to eq(%w[a = b == c === d => e])
  end

  it 'survives invalid bytes and non-ASCII text' do
    source = "const café = 'naïve' \xFF\n export default 1".dup.force_encoding(Encoding::UTF_8)

    expect(values(source)).to include('const', 'naïve', 'export', 'default')
  end

  it 'returns no tokens for an empty source' do
    expect(tokens('')).to eq([])
  end
end
