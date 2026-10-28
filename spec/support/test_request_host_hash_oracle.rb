# frozen_string_literal: true

# Fixed Hash operations run on independently constructed objects; parsed source
# stays inert. Named reachability uses object identity, without production
# summary types or private helpers. Source and concrete operations are paired
# explicitly so the oracle never interprets the Ruby it asks Woods to parse.
require 'active_support/core_ext/hash/deep_merge'
require 'active_support/core_ext/hash/reverse_merge'
require 'active_support/core_ext/hash/except'

module TestRequestHostHashOracle # rubocop:disable Metrics/ModuleLength
  ADMIN = 'admin'.dup.freeze
  FINAL = 'final'.dup.freeze
  SHOP = 'shop'.dup.freeze
  RUNTIME = Object.new.freeze
  ABSENT = Object.new.freeze
  KEYS = [:subdomain, 'subdomain'].freeze
  PROMOTED = { ADMIN => 'admin', FINAL => 'final' }.compare_by_identity.freeze
  Program = Struct.new(:name, :expression, :worlds)
  Operation = Struct.new(:name, :source, :apply)

  module_function

  # Opaque outcomes are independent witnesses, not an implementation of a key
  # conversion. A key may be absent, retain the original object, become nil or
  # contain an anonymous runtime value. A fresh equal string has new provenance.
  def opaque_worlds
    [ABSENT, ADMIN, nil, RUNTIME].product([ABSENT, ADMIN, nil, RUNTIME]).map do |symbol, string|
      world_for(symbol, string)
    end
  end

  def runtime_worlds
    [ABSENT, nil, RUNTIME].product([ABSENT, nil, RUNTIME]).map do |symbol, string|
      world_for(symbol, string)
    end
  end

  def world_for(symbol, string)
    {}.tap do |hash|
      hash[:subdomain] = symbol unless symbol.equal?(ABSENT)
      hash['subdomain'] = string unless string.equal?(ABSENT)
    end
  end

  def opaque_source
    "{ **attributes_for(:url, subdomain: 'admin').customize }"
  end

  def selector_choices
    dynamic = KEYS + [:locale]
    {
      '' => [[]], ':subdomain' => [[:subdomain]], "'subdomain'" => [['subdomain']],
      ":subdomain, 'subdomain'" => [KEYS], ':locale' => [[:locale]],
      'runtime_key' => dynamic.map { |key| [key] },
      ':subdomain, runtime_key' => dynamic.map { |key| [:subdomain, key] },
      "'subdomain', runtime_key" => dynamic.map { |key| ['subdomain', key] },
      ":subdomain, 'subdomain', runtime_key" => dynamic.map { |key| KEYS + [key] }
    }
  end

  def operation(name, &apply)
    Operation.new(name, ->(text) { "(#{text}).#{name}" }, apply)
  end

  def selector_operations
    selector_choices.flat_map do |source, choices|
      %i[slice except except!].map do |method|
        operation("#{method}(#{source})") do |worlds|
          worlds.flat_map { |world| choices.map { |keys| world.dup.public_send(method, *keys) } }
        end
      end
    end
  end

  def write_operation(method, source, operand)
    operation("#{method}(#{source})") do |worlds|
      worlds.map { |world| world.dup.public_send(method, operand) }
    end
  end

  def write_operations
    operands = [["subdomain: 'final'", { subdomain: FINAL }], ["'subdomain' => 'shop'", { 'subdomain' => SHOP }]]
    %i[merge merge! deep_merge deep_merge!].flat_map do |method|
      operands.map { |source, operand| write_operation(method, source, operand) }
    end
  end

  def runtime_operations
    [operation('merge(runtime_options)') do |worlds|
      worlds.flat_map { |world| runtime_worlds.map { |right| world.merge(right) } }
    end,
     operation("merge(runtime_key => 'shop')") do |worlds|
       worlds.flat_map { |world| (KEYS + [:locale]).map { |key| world.merge(key => SHOP) } }
     end]
  end

  def copy_operations
    [Operation.new('copy', ->(text) { "{ **(#{text}) }" }, ->(worlds) { worlds.map { |world| { **world } } }),
     operation('dup') { |worlds| worlds.map(&:dup) },
     operation('compact') { |worlds| worlds.map(&:compact) }]
  end

  def core_operations
    fallbacks = %i[reverse_merge reverse_merge!].map do |method|
      write_operation(method, "subdomain: 'final'", { subdomain: FINAL })
    end
    write_operations + fallbacks + runtime_operations + copy_operations
  end

  def roots
    [Program.new('named', "attributes_for(:url, subdomain: 'admin')", [{ subdomain: ADMIN }]),
     Program.new('opaque-copy', opaque_source, opaque_worlds),
     Program.new('reverse-plain', "attributes_for(:url, subdomain: 'final').reverse_merge(#{opaque_source})",
                 opaque_worlds.map { |hash| { subdomain: FINAL }.reverse_merge(hash) })]
  end

  def each_sequence(root, sequences)
    sequences.each do |sequence|
      expression = sequence.reduce(root.expression) { |text, entry| entry.source.call(text) }
      worlds = sequence.reduce(root.worlds) { |hashes, entry| entry.apply.call(hashes) }
      yield Program.new([root.name, *sequence.map(&:name)].join(' / '), expression, worlds)
    end
  end

  def each_program(&block)
    return enum_for(:each_program) unless block_given?

    core = core_operations
    selectors = selector_operations
    roots.each { |root| each_sequence(root, core.repeated_permutation(2), &block) }
    each_sequence(Program.new('selectors', opaque_source, opaque_worlds), selectors.repeated_permutation(2), &block)
    # Both orders check stale same-key writes and survival of opposite keys.
    mixed = selectors.product(core.first(10)).flat_map { |pair| [pair, pair.reverse] }
    each_sequence(Program.new('mixed', opaque_source, opaque_worlds), mixed, &block)
    each_grouping_program(&block)
  end

  # A fixed concrete overlay, never a summary of presence or abstract keys.
  def overlay_program(name, left, right_source, right_worlds, method = :merge)
    worlds = left.worlds.flat_map do |hash|
      right_worlds.map { |right| hash.dup.public_send(method, right) }
    end
    Program.new(name, "#{left.expression}.#{method}(#{right_source})", worlds)
  end

  def unknown_write(literal, key)
    Program.new(nil, "{ #{literal} => 'shop' }.merge(runtime_options)",
                runtime_worlds.map { |runtime| { key => SHOP }.merge(runtime) })
  end

  def guaranteed_write_program(root, literal, key, method, label = 'nested guaranteed write')
    right = unknown_write(literal, key)
    overlay_program("#{root.name} #{label} #{method}", root, right.expression, right.worlds, method)
  end

  def flat_write_program(root, literal, key, method)
    write = "{ #{literal} => 'shop' }"
    replacement = { key => SHOP }
    worlds = root.worlds.flat_map do |hash|
      runtime_worlds.map { |runtime| hash.dup.public_send(method, replacement, runtime, replacement) }
    end
    Program.new("#{root.name} flat write unknown write #{method}",
                "#{root.expression}.#{method}(#{write}, runtime_options, #{write})", worlds)
  end

  def final_write_program(root, literal, key, method)
    right = unknown_write(literal, key)
    overlay_program("#{root.name} nested write unknown write #{method}", root,
                    "#{right.expression}.merge({ #{literal} => 'shop' })",
                    right.worlds.map { |hash| hash.merge(key => SHOP) }, method)
  end

  def nullable_write_program(root, literal, key, method)
    # Compaction before the outer merge can remove the replacement entirely.
    overlay_program("#{root.name} compact can remove replacement #{method}", root,
                    "{ #{literal} => runtime_value }.compact",
                    [nil, SHOP].map { |value| { key => value }.compact }, method)
  end

  def merge_group_programs(root, literal, key, method)
    [guaranteed_write_program(root, literal, key, method), flat_write_program(root, literal, key, method),
     final_write_program(root, literal, key, method), nullable_write_program(root, literal, key, method)]
  end

  def reverse_group_program(root, literal, key, method)
    right = unknown_write(literal, key)
    overlay_program("#{root.name} nested present receiver #{method}", right, root.expression, root.worlds, method)
  end

  def deep_group_programs(root, literal, key, method)
    [guaranteed_write_program(root, literal, key, method, 'deep merge grouped definite write'),
     overlay_program("#{root.name} deep merge scalar with nested hash #{method}", root,
                     "#{literal} => { locale: 'en' }", [{ key => { locale: 'en' } }], method)]
  end

  def non_nil_operand(literal, key)
    other = key.is_a?(Symbol) ? FINAL : 'other'.dup
    other_source = key.is_a?(Symbol) ? 'final' : 'other'
    worlds = (KEYS + [:locale]).map { |selector| { key => SHOP }.merge({ key => other }.except(selector)).compact }
    source = "{ #{literal} => 'shop' }.merge({ #{literal} => '#{other_source}' }.except(runtime_key)).compact"
    Program.new('non-nil uncertain value remains present through compact', source, worlds)
  end

  def all_nil_operand(literal, key)
    worlds = (KEYS + [:locale]).map { |selector| { key => nil }.merge({ key => nil }.except(selector)).compact }
    Program.new('all-nil grouped value disappears in compact',
                "{ #{literal} => nil }.merge({ #{literal} => nil }.except(runtime_key)).compact", worlds)
  end

  def compact_group_programs(root, literal, key)
    [non_nil_operand(literal, key), all_nil_operand(literal, key)].map do |right|
      overlay_program("#{root.name} #{right.name}", root, right.expression, right.worlds)
    end
  end

  def hash_splat_program(root, literal, key)
    worlds = root.worlds.flat_map do |hash|
      runtime_worlds.map { |runtime| { **hash, **{ key => SHOP, **runtime } } }
    end
    Program.new("#{root.name} hash-splat grouping",
                "{ **(#{root.expression}), **{ #{literal} => 'shop', **runtime_options } }", worlds)
  end

  def final_group_programs(root, literal, key)
    [Program.new("#{root.name} nil write then compact", "#{root.expression}.merge(#{literal} => nil).compact",
                 root.worlds.map { |hash| hash.merge(key => nil).compact }),
     overlay_program("#{root.name} reverse fallback writes cannot overwrite receiver", root,
                     "{ #{literal} => 'shop' }", [{ key => SHOP }], :reverse_merge),
     hash_splat_program(root, literal, key)]
  end

  def grouping_programs(literal, key)
    root = Program.new(key.class.to_s, "(#{opaque_source}).slice(#{literal})",
                       opaque_worlds.map { |hash| hash.slice(key) })
    merges = %i[merge merge!].flat_map { |method| merge_group_programs(root, literal, key, method) }
    reverses = %i[reverse_merge reverse_merge!].map { |method| reverse_group_program(root, literal, key, method) }
    deep = %i[deep_merge deep_merge!].flat_map { |method| deep_group_programs(root, literal, key, method) }
    merges + reverses + deep + compact_group_programs(root, literal, key) + final_group_programs(root, literal, key)
  end

  def literal_string_programs
    root = Program.new(nil, "(#{opaque_source}).slice('subdomain')",
                       opaque_worlds.map { |hash| hash.slice('subdomain') })
    # Equal value, different object: the fresh string-key write is unpromoted.
    fresh_admin = 'admin'.dup
    strings = ['', 'chosen'].map { |value| { 'subdomain' => value }.compact }
    [overlay_program('interpolated string remains non-nil through compact', root,
                     %q({ 'subdomain' => "#{runtime_value}" }.compact), strings),
     overlay_program('fresh string equal to original literal', root,
                     "'subdomain' => 'admin'", [{ 'subdomain' => fresh_admin }])]
  end

  def each_grouping_program(&block)
    [[':subdomain', :subdomain], ["'subdomain'", 'subdomain']].each do |literal, key|
      grouping_programs(literal, key).each(&block)
    end
    literal_string_programs.each(&block)
  end

  def source_for(entry)
    "host! 'shop.example.test'\nroot_url(**#{entry.expression})\nget '/settings'\n"
  end

  def expected_hints(entry)
    retained = entry.worlds.flat_map { |hash| KEYS.filter_map { |key| PROMOTED[hash[key]] if hash.key?(key) } }
    (['shop'] + retained).uniq.sort
  end

  def anonymous_string_value?(key, value)
    key.is_a?(String) && (value.equal?(RUNTIME) || value.nil?)
  end

  def concrete_hosts(world)
    # Anonymous runtime string values stay outside inference, while their
    # ability to overwrite tracked provenance is checked by expected_hints.
    # Explicit literal string writes still participate in this certainty check.
    values = KEYS.filter_map do |key|
      next unless world.key?(key)
      next if anonymous_string_value?(key, world[key])

      [world[key]]
    end.flatten(1)
    return nil unless values.all?(String)

    (['shop'] + values).uniq.sort
  end

  def hint_failures(entry, hints)
    expected = expected_hints(entry)
    hints == expected ? [] : ["stale or missing named hint: #{hints.inspect} != #{expected.inspect}"]
  end

  def certainty_failures(entry, known)
    if known && entry.worlds.any? { |world| concrete_hosts(world) != known }
      ["false certainty: #{known.inspect} is not true in every bounded world"]
    else
      []
    end
  end

  def absence_failures(entry, known)
    if entry.worlds.all? { |world| (world.keys & KEYS).empty? } && known != ['shop']
      ['lost definite absence after plain selection/removal']
    else
      []
    end
  end

  def violations(entry, host)
    source = source_for(entry)
    hints = host.literal_subdomains(source).sort
    known = host.subdomains(source)&.sort
    hint_failures(entry, hints) + certainty_failures(entry, known) + absence_failures(entry, known)
  end
end
