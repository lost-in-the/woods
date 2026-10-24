# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/template_locals'

RSpec.describe Woods::Extractors::TemplateLocals do
  def renders(code)
    described_class.scan(code)[:renders].map { |render| render.except(:line) }
  end

  it 'reads the locals a partial render by name passes, with its line' do
    result = described_class.scan(%(\n render "posts/card", post: @post, size: 2 ;))
    expect(result[:renders]).to eq([{ partial: 'posts/card', locals: %w[post size], implicit_local: nil,
                                      dynamic_locals: false, line: 2 }])
  end

  it 'reads the options form: locals, and the implicit local of an object or collection' do
    code = <<~RUBY
      render partial: "posts/card", locals: { post: @post } ;
      render partial: "posts/card", collection: @posts, as: :item ;
      render(partial: "shared/row", object: @row) ;
    RUBY
    expect(renders(code)).to eq(
      [{ partial: 'posts/card', locals: ['post'], implicit_local: nil, dynamic_locals: false },
       { partial: 'posts/card', locals: [], implicit_local: 'item', dynamic_locals: false },
       { partial: 'shared/row', locals: [], implicit_local: 'row', dynamic_locals: false }]
    )
  end

  it 'marks locals it cannot name as dynamic and skips renders with no literal partial' do
    code = <<~RUBY
      render "posts/card", options ;
      render partial: "posts/card", locals: extra ;
      render "posts/card", **extra ;
      render @posts ;
      render template: "posts/show" ;
      render "posts/\#{kind}" ;
    RUBY
    expect(renders(code).map { |r| [r[:partial], r[:dynamic_locals]] })
      .to eq([['posts/card', true], ['posts/card', true], ['posts/card', true]])
  end

  it 'reads bare identifiers and literal local_assigns keys, wide rather than narrow' do
    code = %(link_to post.title, post ; if local_assigns[:extra] ; current_user ; end ; local_assigns.fetch(:size, 1) ;)
    result = described_class.scan(code)
    expect(result[:reads]).to eq(%w[current_user extra post size])
    expect(result[:dynamic]).to be(false)
  end

  it 'marks a template that reaches locals by a computed key or binding as dynamic' do
    expect(described_class.scan('local_assigns.each { |k, v| v } ;')[:dynamic]).to be(true)
    expect(described_class.scan('local_assigns[key] ;')[:dynamic]).to be(true)
    expect(described_class.scan('binding.local_variable_get(:post) ;')[:dynamic]).to be(true)
  end

  it 'parses a strict-locals declaration' do
    expect(described_class.declared('post:, size: 1, **rest'))
      .to eq(required: ['post'], optional: ['size'], any: true)
    expect(described_class.declared('')).to eq(required: [], optional: [], any: false)
    expect(described_class.declared('post:, (')).to be_nil
  end
end
