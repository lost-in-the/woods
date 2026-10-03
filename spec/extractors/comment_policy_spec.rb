# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods'
require 'woods/extractors/comment_blanking'
require 'woods/extractors/shared_dependency_scanner'
require 'woods/extractors/view_template_extractor'

# One policy for every dependency scan: a reference that appears only in a
# comment is prose, and prose never produces an edge.
RSpec.describe 'Comment policy for dependency scans' do
  describe Woods::Extractors::CommentBlanking do
    it 'blanks Ruby line, trailing, and block comments and keeps every byte offset' do
      source = <<~RUBY
        # see Widget::Importer
        total = 1 # WidgetService.call
        =begin
        LedgerJob.perform_later
        =end
        done
      RUBY

      blanked = described_class.ruby(source)

      expect(blanked.bytesize).to eq(source.bytesize)
      expect(blanked.lines.map(&:rstrip)).to eq(['', 'total = 1', '', '', '', 'done'])
    end

    it 'keeps a # that sits in a string, a heredoc, or an interpolation' do
      source = <<~'RUBY'
        label = "Tag #ruby #{Widget.count}"
        body = <<~TEXT
          # not a comment: WidgetService.call
        TEXT
      RUBY

      expect(described_class.ruby(source)).to eq(source)
    end

    it 'returns the same object when the source has no comment' do
      source = "class Widget\nend\n"

      expect(described_class.ruby(source)).to equal(source)
    end

    it 'blanks by byte, so multibyte text before a comment does not shift it' do
      source = "name = 'Zoë' # WidgetService.call\nLedgerService.call\n"

      blanked = described_class.ruby(source)

      expect(blanked.bytesize).to eq(source.bytesize)
      expect(blanked).to include("name = 'Zoë'", 'LedgerService.call')
      expect(blanked).not_to include('WidgetService')
    end
  end

  describe 'shared Ruby scans' do
    let(:scanner) do
      Class.new do
        include Woods::Extractors::SharedDependencyScanner
        include Woods::Extractors::RouteHelperResolver

        def initialize
          @route_helper_map = {
            'widgets' => { controller: 'WidgetsController', action: 'index', path: '/widgets', verb: 'GET' }
          }
        end
      end.new
    end

    let(:commented) do
      <<~RUBY
        # see Widget, WidgetService.call, LedgerJob.perform_later, WidgetMailer.created
        # link_to widgets_path
        # form_with url: widgets_path do
        total = 1 # Widget WidgetService.call LedgerJob.perform_later WidgetMailer.created widgets_url
        =begin
        Widget
        WidgetService.call
        LedgerJob.perform_later
        WidgetMailer.created.deliver_later
        redirect_to widgets_path
        form_with url: widgets_path do
        =end
      RUBY
    end

    before do
      allow(Woods::ModelNameCache).to receive(:model_names_regex).and_return(/\b(?:Widget)\b/)
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    after { Woods::ModelNameCache.reset! }

    {
      scan_model_dependencies: 'Widget.first',
      scan_service_dependencies: 'WidgetService.call',
      scan_job_dependencies: 'LedgerJob.perform_later',
      scan_mailer_dependencies: 'WidgetMailer.created.deliver_later',
      scan_navigation_dependencies: 'redirect_to widgets_path',
      scan_form_dependencies: "form_with url: widgets_path do |f|\nend"
    }.each do |scan, live_code|
      it "#{scan} records no edge for a reference inside a comment" do
        expect(scanner.public_send(scan, commented)).to eq([])
      end

      it "#{scan} still records the reference in code beside a comment" do
        expect(scanner.public_send(scan, "#{commented}#{live_code}\n")).not_to be_empty
      end
    end

    it 'scan_model_dependencies keeps a reference in a heredoc line that starts with #' do
      source = "sql = <<~SQL\n  # \#{Widget.table_name}\nSQL\n"

      expect(scanner.scan_model_dependencies(source).map { |dep| dep[:target] }).to eq(['Widget'])
    end

    it 'ReferencePatterns resolves a reference after a comment at its own offset' do
      source = <<~RUBY
        class Shipment
          # PingJob.perform_later is how a retry starts
          def retry!
            LedgerJob.perform_later
          end
        end
      RUBY

      expect(Woods::Extractors::ReferencePatterns.job_enqueues(source)).to eq(['LedgerJob'])
    end
  end

  describe 'extractor scans' do
    include_context 'extractor setup'

    before do
      Woods.configure unless Woods.configuration
      allow(Woods.configuration).to receive(:extract_navigation_edges).and_return(true)
    end

    def template_unit(relative_path, source)
      path = create_file(relative_path, source)
      create_file('app/views/widgets/_row.html.erb', '<p>row</p>')
      extractor = Woods::Extractors::ViewTemplateExtractor.new
      extractor.instance_variable_set(
        :@route_helper_map,
        { 'ledgers' => { controller: 'LedgersController', action: 'index', path: '/ledgers', verb: 'GET' } }
      )
      extractor.extract_view_template_file(path)
    end

    def edges(unit)
      unit.dependencies.reject { |dep| dep[:via] == :view_render }
    end

    it 'records no edge for a render or route helper inside an ERB comment' do
      unit = template_unit('app/views/widgets/index.html.erb', <<~ERB)
        <%# render 'row' %>
        <%# link_to 'Ledgers', ledgers_path %>
        <% # render partial: 'row' %>
        <p>plain</p>
      ERB

      expect(edges(unit)).to eq([])
      expect(unit.metadata[:partials_rendered]).to eq([])
    end

    it 'still records an ERB render beside a comment' do
      unit = template_unit('app/views/widgets/index.html.erb', <<~ERB)
        <%# link_to 'Ledgers', ledgers_path %>
        <%= render 'row' %>
      ERB

      expect(edges(unit)).to eq([{ type: :view_template, target: 'widgets/_row.html.erb', via: :render }])
    end

    it 'records no edge for a render or route helper inside a HAML comment' do
      unit = template_unit('app/views/widgets/index.html.haml', <<~HAML)
        -# = render 'row'
        - # link_to 'Ledgers', ledgers_path
        %p plain
      HAML

      expect(edges(unit)).to eq([])
    end

    it 'records no edge for a partial or route helper inside a Jbuilder comment' do
      unit = template_unit('app/views/widgets/index.json.jbuilder', <<~RUBY)
        # json.partial! 'row', widget: @widget
        # json.url ledgers_url
        json.id @widget.id
      RUBY

      expect(edges(unit)).to eq([])
      expect(unit.metadata[:partials_rendered]).to eq([])
    end
  end

  describe 'complexity' do
    budget_seconds = 1.0

    around do |example|
      if Regexp.respond_to?(:timeout=)
        previous = Regexp.timeout
        Regexp.timeout = budget_seconds
        begin
          example.run
        ensure
          Regexp.timeout = previous
        end
      else
        Timeout.timeout(budget_seconds * 5) { example.run }
      end
    end

    {
      'fifty thousand comment lines' => "# Widget\n" * 50_000,
      'one comment of fifty thousand hashes' => '#' * 50_000,
      'ten thousand trailing comments' => "x = 1 # WidgetService.call\n" * 10_000,
      'ten thousand unterminated block comments' => "=begin\n" * 10_000,
      'ten thousand strings holding a hash' => %(a = "#b"\n) * 10_000
    }.each do |label, source|
      it "blanks #{label} within #{budget_seconds}s" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Woods::Extractors::CommentBlanking.ruby(source)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < budget_seconds
      end
    end
  end
end
