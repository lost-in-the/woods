# frozen_string_literal: true

require 'prism'
require 'strscan'

module Woods
  module Extractors
    # Works out which subdomain a test file's requests are made on, when the
    # file says so with a literal.
    #
    # Recognized: `host! "shop.example.test"`, Capybara app/default hosts,
    # a `subdomain:` option, and a call to one of the configured helper names
    # (`config.test_subdomain_helpers`) with a literal argument. A file may
    # name several subdomains; none, an interpolated request value, or an
    # unresolved named field in returned options means unknown.
    #
    # @example
    #   TestRequestHost.subdomain(%(before { host! "shop.example.test" }))  # => "shop"
    #   TestRequestHost.subdomains(%(host! "shop.example.test"\nhost! "app.example.test"))  # => ["shop", "app"]
    #   TestRequestHost.subdomain(%(visit "/settings"))                     # => nil
    #
    module TestRequestHost
      # Must equal `Woods::Configuration#test_subdomain_helpers`' default.
      DEFAULT_HELPERS = %w[with_subdomain use_subdomain using_subdomain set_subdomain switch_to_subdomain
                           on_subdomain].freeze

      LITERAL = /(?:"([^"\n]*)"|'([^'\n]*)'|:(\w+))/
      HOST = /\bhost![ \t(]+(?:"([^"\n]*)"|'([^'\n]*)')/
      HOST_CALL = /\bhost![ \t(]/
      # A whole string literal shaped like a host name, read in a file that
      # calls host!, since host! may read it from data.
      HOST_STRING = /(?:"([a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+)"|'([a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+)')/i
      # Last labels a test host ends in. A dotted literal that ends otherwise
      # (`order.created`, `app.errors.title`) is a key or event name.
      HOST_TLD = /\A(?:test|example|invalid|localhost|local|internal|com|net|org|edu|gov|io|dev|app|info|biz|me|co|xyz|
                       uk|us|ca|de|fr|au|nz|jp)\z/ix
      # Literal argument hashes of these factory/model calls hold record
      # attributes. This is a name-based heuristic, without value-flow analysis.
      RECORD_CALLS = %i[create create! create_list build build_list build_stubbed attributes_for new find_by find_by! where].freeze
      HASH_TRANSFORMS = %i[merge merge! deep_merge deep_merge! reverse_merge reverse_merge! except except! slice slice!
                           stringify_keys stringify_keys! symbolize_keys symbolize_keys! with_indifferent_access].freeze
      HASH_MERGES = %i[merge merge! deep_merge deep_merge! reverse_merge reverse_merge!].freeze
      REQUEST_CALLS = %i[visit get post put patch delete head options url_for].freeze
      private_constant :RECORD_CALLS, :HASH_TRANSFORMS, :HASH_MERGES, :REQUEST_CALLS
      FILE_EXTENSION = /\.(?:rb|erb|json|csv|txt|png|jpe?g|gif|svg|webp|pdf|ya?ml|xml|html?|zip|gz|js|css|md|log)\z/i
      CAPYBARA_SPEC = /
        (?<![\w:@$])visit[ \t(]|\.visit[ \t(]
        |(?:\btype:|:type[ \t]*=>)[ \t]*:(?:feature|system)\b
        |\brequire(?:_relative)?[ \t(]+["'][^"'\n]*acceptance_helper["']
      /x
      APP_HOST = %r{\b(?:app_host|default_host)[ \t]*=[ \t]*["']https?://([^"'/\n:]+)}
      CAPYBARA_HOST = %r{\bCapybara\.(app_host|default_host)[ \t]*=[ \t]*["']https?://([^"'/\n:]+)}
      OPTION_KEY = /(?:\bsubdomain:|:subdomain[ \t]*=>)/
      OPTION_VALUE = /[ \t]*#{LITERAL}/
      private_constant :OPTION_KEY, :OPTION_VALUE
      OPTION = /#{OPTION_KEY}#{OPTION_VALUE}/
      LITERAL_OPTION = /\A#{OPTION}\z/
      private_constant :LITERAL_OPTION
      # Each key has independent presence/value and provenance. nil is absent,
      # :maybe may be absent, :present is present with an unknown value, and an
      # association is a definite write. Unknown values must not erase presence.
      # Nilness (:nil/:non_nil/:unknown) composes separately for compact.
      ReturnedKey = Struct.new(:value, :possible, :nilness)
      ABSENT_KEY = ReturnedKey.new(nil, nil).freeze
      ReturnedField = Struct.new(:symbol, :string, :plain_keys)
      private_constant :ReturnedKey, :ABSENT_KEY, :ReturnedField
      # An IPv4 host, with an optional port. Rails reads no subdomain from an
      # IP host (`ActionDispatch::Http::URL.extract_subdomains`).
      IP_HOST = /\A\d++(?:\.\d++){3}(?::\d++)?\z/

      module_function

      # @param source [String] Ruby source of a test file
      # @return [String, nil] the one subdomain the file names ("" for a host
      #   without one), or nil when it is unknown
      def subdomain(source)
        found = subdomains(source)
        found&.one? ? found.first : nil
      end

      # @param source [String] Ruby source of a test file
      # @return [Array<String>, nil] every subdomain the file names, or nil
      #   when it names none, interpolates one or leaves a named field unresolved
      def subdomains(source)
        return nil unless hosts_literal?(source)

        found = literal_subdomains(source)
        found.empty? ? nil : found
      end

      # @param source [String] Ruby source of a test file
      # @return [Array<String>] the subdomains the file names with a literal,
      #   even beside an interpolated one
      def literal_subdomains(source)
        (hosts(source).map { |host| subdomain_of(host) } + named(source)).reject { |value| value.include?('#{') }.uniq
      end

      # Does the file supply its own host hints, even when ambiguous?
      #
      # @param source [String] Ruby source of a test file
      # @return [Boolean]
      def specifies_host?(source)
        (hosts(source) + named(source)).any? || source.match?(HOST_CALL)
      end

      # Does the Capybara default host apply? Only to feature and system
      # specs: a file that visits, is tagged `type: :feature` or `:system`,
      # or requires the acceptance helper. A request spec never gets it.
      #
      # @param source [String] Ruby source of a test file
      # @return [Boolean]
      def capybara_spec?(source)
        source.match?(CAPYBARA_SPEC)
      end

      # Resolve the Capybara default from the catalog's support source.
      # app_host takes precedence over default_host. A literal host wins and
      # a configured helper's literal argument never cancels it; without a
      # literal, a lone helper literal is the default. An interpolated host
      # counts for nothing. Competing defaults remain unknown. No support code
      # is executed.
      #
      # @param source [String] Ruby source of the test support files
      # @return [String, nil]
      def capybara_subdomain(source)
        literals, helper_literals = capybara_hosts(source)
        found = literals.empty? ? helper_literals : literals
        found.one? ? found.first : nil
      end

      # Every subdomain the support source can put the Capybara host on: its
      # literal hosts, widened by configured helpers' literal arguments.
      #
      # @param source [String] Ruby source of the test support files
      # @return [Array<String>]
      def capybara_subdomains(source)
        capybara_hosts(source).inject(:|)
      end

      # @return [Array(Array<String>, Array<String>)] literal host subdomains
      #   and configured helpers' literal arguments
      def capybara_hosts(source)
        source = source.each_line.grep_v(/\A[ \t]*#/).join
        configured = source.scan(CAPYBARA_HOST).group_by(&:first)
        hosts = (configured['app_host'] || configured['default_host'] || []).map(&:last)
        literals = hosts.map { |host| subdomain_of(host) }.reject { |value| value.include?('#{') }.uniq
        helper_literals = helper_pattern ? source.scan(helper_pattern).map { |captures| captures.compact.first } : []
        [literals, helper_literals.uniq]
      end

      # @return [Array<String>] the configured helper names
      def helpers
        configured = Woods.configuration if Woods.respond_to?(:configuration)
        configured.respond_to?(:test_subdomain_helpers) ? configured.test_subdomain_helpers : DEFAULT_HELPERS
      end

      def hosts(source)
        found = (source.scan(HOST) + source.scan(APP_HOST)).map { |captures| captures.compact.first }
        found + host_strings(source)
      end

      # Every literal host string counts as a named host once the file calls
      # host!, whether host! takes it directly or reads it from data.
      def host_strings(source)
        return [] unless source.match?(HOST_CALL)

        source.scan(HOST_STRING).map { |captures| captures.compact.first }
              .select { |host| host.split('.').last.match?(HOST_TLD) && !host.match?(FILE_EXTENSION) }
      end

      # An interpolated host or subdomain anywhere makes the file's subdomain
      # depend on runtime data, whatever literals sit beside it.
      def hosts_literal?(source)
        (hosts(source) + named(source)).none? { |value| value.include?('#{') }
      end

      def named(source)
        values = options(source)
        values += source.scan(helper_pattern) if helper_pattern
        values.map { |captures| captures.compact.first }
      end

      # `subdomain:` options, leaving out those given to a record call.
      def options(source)
        return [] unless source.match?(OPTION_KEY)

        record_options, uncertain = record_option_offsets(source)
        found = []
        # StringScanner keeps the source's word boundaries and capture encoding,
        # while pos/matched_size use the same byte offsets as Prism.
        scanner = StringScanner.new(source)
        while scanner.skip_until(OPTION_KEY)
          next if record_options.key?(scanner.pos - scanner.matched_size)

          # Skip record keys before reading a value that might span executable
          # interpolation containing another option.
          # strscan 3.0's captures turns unmatched groups into empty strings.
          # Indexed access keeps them nil without discarding real empty values.
          found << [scanner[1], scanner[2], scanner[3]] if scanner.scan(OPTION_VALUE)
        end
        # Reuse the existing unknown-host representation without inventing a
        # literal for an unresolved returned hash.
        found << ["\#{unknown request options}"] if uncertain
        found
      end

      # Track record hash ownership separately from literal containment, which
      # survives arbitrary call arguments. Receivers and bounded hash operands
      # retain data context, while other call arguments and blocks own theirs.
      # Direct returned factory hashes are resolved separately, never by treating
      # every key encountered along a receiver chain as its final value.
      def record_option_offsets(source)
        offsets = {}
        returned_roots = {}
        selected = []
        pending = [[Prism.parse(source).value, false, false]]
        until pending.empty?
          node, record, literal = pending.pop
          record = literal = true if returned_roots.key?(node)
          offsets[node.key.location.start_offset] = true if record && subdomain_association?(node)
          record_text_offsets(node, offsets) if literal

          if node.is_a?(Prism::CallNode)
            request = REQUEST_CALLS.include?(node.name) || node.name.to_s.end_with?('_url', '_path')
            if request && node.arguments
              node.arguments.arguments.each do |argument|
                factory, value = returned_option(argument)
                next unless factory

                returned_roots[argument] = true
                selected << value
              end
            end
            node.compact_child_nodes.each do |child|
              argument = child.equal?(node.arguments)
              record_argument = argument && RECORD_CALLS.include?(node.name)
              data = child.equal?(node.receiver) || (argument && HASH_TRANSFORMS.include?(node.name))
              pending << [child, record_argument || (record && data), literal || record_argument]
            end
          else
            node.compact_child_nodes.each { |child| pending << [child, record, literal] }
          end
        end
        uncertain = false
        selected.each do |field|
          # An unhinted opaque string key remains outside the named-field
          # policy. Explicit string writes carry provenance but are not promoted.
          uncertain ||= !field.string.possible.nil? ||
                        (!field.symbol.value.nil? && !literal_option?(field.symbol.value))
          # Possible hints keep redirects reachable even while the host is
          # unknown. The tree avoids copying growing sets along merge chains.
          pending = [field.symbol.possible, field.string.possible]
          visited = {}.compare_by_identity
          until pending.empty?
            value = pending.pop
            if value.is_a?(Array)
              next if visited[value]

              visited[value] = true
              pending.concat(value)
            elsif literal_option?(value)
              offsets.delete(value.key.location.start_offset)
            end
          end
        end
        [offsets, uncertain]
      end
      private_class_method :record_option_offsets

      def subdomain_association?(node)
        node.is_a?(Prism::AssocNode) && node.key.is_a?(Prism::SymbolNode) && node.key.unescaped == 'subdomain'
      end
      private_class_method :subdomain_association?

      def literal_option?(node)
        node.is_a?(Prism::AssocNode) &&
          (node.value.is_a?(Prism::StringNode) || node.value.is_a?(Prism::SymbolNode)) &&
          node.location.slice.match?(LITERAL_OPTION)
      end
      private_class_method :literal_option?

      def record_text_offsets(node, offsets)
        location = case node
                   when Prism::StringNode, Prism::RegularExpressionNode, Prism::XStringNode
                     node.content_loc
                   when Prism::SymbolNode
                     node.value_loc
                   end
        return unless location

        # Match the key alone: a textual option value may span interpolation
        # parts. Embedded Ruby is visited separately, preserving real calls.
        scanner = StringScanner.new(location.slice)
        offsets[location.start_offset + scanner.pos - scanner.matched_size] = true while scanner.skip_until(OPTION_KEY)
      end
      private_class_method :record_text_offsets

      # Each summary is [contains_direct_factory, ReturnedField]. Only syntactically
      # named symbolic fields in connected hash operands are considered; unnamed
      # runtime options, locals, helper returns and factory defaults are outside
      # this heuristic. The postorder stack avoids recursive Ruby calls.
      def returned_option(root)
        values = {}
        option = false
        pending = [[root, nil]]
        until pending.empty?
          node, children = pending.pop
          unless children
            children = returned_option_children(node)
            pending << [node, children]
            children.reverse_each { |child| pending << [child, nil] }
            next
          end

          summaries = children.map { |child| values.fetch(child) }
          option ||= subdomain_association?(node)
          factory = (node.is_a?(Prism::CallNode) && node.name == :attributes_for) || summaries.any?(&:first)
          values[node] = [factory, returned_option_value(node, summaries.map(&:last))]
        end
        factory, value = values.fetch(root)
        # Even an opaque merge operand alone introduces no host hint without a
        # named field. Do not speculate about defaults based on other source.
        [factory && option, value]
      end
      private_class_method :returned_option

      def returned_option_children(node)
        case node
        when Prism::ArgumentsNode then node.arguments
        when Prism::HashNode, Prism::KeywordHashNode then node.elements
        when Prism::AssocSplatNode then [node.value].compact
        when Prism::ParenthesesNode then [node.body].compact
        when Prism::StatementsNode then [node.body.last].compact
        when Prism::CallNode
          return [node.arguments].compact if node.name == :attributes_for
          return [] unless node.receiver

          [node.receiver] + (HASH_MERGES.include?(node.name) ? (node.arguments&.arguments || []) : [])
        else
          []
        end
      end
      private_class_method :returned_option_children

      def returned_option_value(node, values)
        case node
        when Prism::ArgumentsNode, Prism::HashNode, Prism::KeywordHashNode
          merge_returned_fields(values)
        when Prism::AssocSplatNode, Prism::StatementsNode, Prism::ParenthesesNode
          values.first || unknown_returned_field([])
        when Prism::AssocNode
          case static_option_key(node.key)
          when :subdomain
            ReturnedField.new(ReturnedKey.new(node, node, returned_value_nilness(node.value)), ABSENT_KEY, true)
          when :string_subdomain
            ReturnedField.new(ABSENT_KEY, ReturnedKey.new(node, node, returned_value_nilness(node.value)), true)
          when :other then ReturnedField.new(ABSENT_KEY, ABSENT_KEY, true)
          else unknown_returned_field([], plain_keys: true)
          end
        when Prism::CallNode
          returned_call_option(node, values)
        else
          unknown_returned_field([])
        end
      end
      private_class_method :returned_option_value

      def returned_call_option(node, values)
        return unknown_returned_field(values) if node.block
        return merge_returned_fields(values) if node.name == :attributes_for
        return unknown_returned_field([]) unless node.receiver

        receiver = values.first
        arguments = node.arguments&.arguments || []
        # Key conversion and arbitrary receivers stay opaque. A subsequent
        # symbol write cannot establish how string writes/selectors behave.
        return unknown_returned_field(values) unless receiver.plain_keys

        case node.name
        when :merge, :merge!, :deep_merge, :deep_merge!
          merge_returned_fields(values)
        when :reverse_merge, :reverse_merge!
          return unknown_returned_field(values, plain_keys: true) unless arguments.one?

          unless values.last.plain_keys
            # The fallback owns merge dispatch and may change copied receiver
            # keys. Bang replaces this plain receiver; non-bang stays opaque.
            opaque = unknown_returned_field(values)
            return node.name == :reverse_merge! ? merge_returned_fields([opaque]) : opaque
          end
          # The fallback merges the receiver, independently for each key.
          merge_returned_fields([values.last, receiver])
        when :dup, :compact
          return unknown_returned_field(values) unless arguments.empty?
          return receiver if node.name == :dup

          ReturnedField.new(compact_returned_key(receiver.symbol), compact_returned_key(receiver.string), true)
        when :except, :except!, :slice
          keys = arguments.map { |argument| static_option_key(argument) }
          return slice_returned_field(receiver, keys) if node.name == :slice

          except_returned_field(receiver, keys)
        else
          # Includes destructive/renaming transforms and arbitrary receiver calls.
          # Even a block on a nominally preserving transform can change the hash.
          unknown_returned_field(values)
        end
      end
      private_class_method :returned_call_option

      # Merge is pointwise last-write precedence. A definitely present right
      # key kills left provenance even when its value is no longer known.
      def merge_returned_fields(fields)
        fields.reduce(ReturnedField.new(ABSENT_KEY, ABSENT_KEY, true)) do |previous, field|
          ReturnedField.new(merge_returned_keys(previous.symbol, field.symbol),
                            merge_returned_keys(previous.string, field.string), true)
        end
      end
      private_class_method :merge_returned_fields

      def merge_returned_keys(previous, field)
        return previous if field.value.nil?
        return field unless field.value == :maybe

        value = previous.value.nil? || previous.value == :maybe ? :maybe : :present
        nilness = previous.value.nil? || previous.nilness == field.nilness ? field.nilness : :unknown
        ReturnedKey.new(value, returned_hint_tree(previous.possible, field.possible), nilness)
      end
      private_class_method :merge_returned_keys

      def optional_returned_key(key)
        key.value.nil? ? key : ReturnedKey.new(:maybe, key.possible, key.nilness)
      end
      private_class_method :optional_returned_key

      def compact_returned_key(key)
        return key if key.value.nil? || key.nilness == :non_nil
        return ABSENT_KEY if key.nilness == :nil

        ReturnedKey.new(:maybe, key.possible, :non_nil)
      end
      private_class_method :compact_returned_key

      # This is only a nil test, not evaluation of the literal's host value.
      def returned_value_nilness(value)
        return :nil if value.is_a?(Prism::NilNode)
        return :non_nil if value.static_literal?

        # Mutable strings lack Prism's static-literal flag, but these intrinsic
        # constructors still return non-nil values without inspecting contents.
        case value
        when Prism::StringNode, Prism::ArrayNode, Prism::HashNode, Prism::InterpolatedStringNode,
             Prism::InterpolatedSymbolNode, Prism::InterpolatedRegularExpressionNode
          :non_nil
        else
          :unknown
        end
      end
      private_class_method :returned_value_nilness

      def except_returned_field(field, keys)
        symbol = keys.include?(:subdomain) ? ABSENT_KEY : field.symbol
        string = keys.include?(:string_subdomain) ? ABSENT_KEY : field.string
        if keys.include?(nil)
          symbol = optional_returned_key(symbol)
          string = optional_returned_key(string)
        end
        ReturnedField.new(symbol, string, true)
      end
      private_class_method :except_returned_field

      def slice_returned_field(field, keys)
        symbol = selected_returned_key(field.symbol, keys.include?(:subdomain), keys.include?(nil))
        string = selected_returned_key(field.string, keys.include?(:string_subdomain), keys.include?(nil))
        ReturnedField.new(symbol, string, true)
      end
      private_class_method :slice_returned_field

      def selected_returned_key(key, selected, dynamic)
        return key if selected

        dynamic ? optional_returned_key(key) : ABSENT_KEY
      end
      private_class_method :selected_returned_key

      def unknown_returned_field(fields, plain_keys: false)
        symbol = returned_hint_tree(*fields.map { |field| field.symbol.possible })
        string = returned_hint_tree(*fields.map { |field| field.string.possible })
        # Opaque dispatch can remove, duplicate, or rename either key. A literal
        # copy later restores Hash dispatch only, never key/value certainty.
        symbol = string = returned_hint_tree(symbol, string) unless plain_keys
        ReturnedField.new(ReturnedKey.new(:maybe, symbol, :unknown),
                          ReturnedKey.new(:maybe, string, :unknown), plain_keys)
      end
      private_class_method :unknown_returned_field

      def returned_hint_tree(*trees)
        trees = trees.compact
        return trees.first if trees.size < 2

        trees
      end
      private_class_method :returned_hint_tree

      # Only the symbolic key is promoted. A string key does not overwrite or
      # remove a symbol key in a plain Hash; key conversions remain unresolved.
      def static_option_key(node)
        return node.unescaped == 'subdomain' ? :subdomain : :other if node.is_a?(Prism::SymbolNode)
        return node.unescaped == 'subdomain' ? :string_subdomain : :other if node.is_a?(Prism::StringNode)

        nil
      end
      private_class_method :static_option_key

      def helper_pattern
        names = helpers
        return nil if names.empty?

        @helper_patterns ||= {}
        @helper_patterns[names] ||= /(?<![\w.:@$])(?:#{Regexp.union(names)})[ \t(]+#{LITERAL}/
      end

      # Everything left of the registrable domain: `a.b.example.test` is "a.b".
      def subdomain_of(host)
        return host if host.include?('#{')
        return '' if host.match?(IP_HOST)

        labels = host.split('.')
        labels.size > tld_length + 1 ? labels[0...-(tld_length + 1)].join('.') : ''
      end

      def tld_length
        return 1 unless defined?(ActionDispatch::Http::URL) && ActionDispatch::Http::URL.respond_to?(:tld_length)

        ActionDispatch::Http::URL.tld_length.to_i
      end
    end
  end
end
