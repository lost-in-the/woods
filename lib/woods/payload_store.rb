# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'forwardable'
require_relative 'generation_pins'

module Woods
  # Writer-side owner of the per-generation payload directories.
  #
  # An index published flat is a directory of independently-written files, so a
  # reader refreshing mid-publish can load a unit from generation N+1 beside a
  # graph from N. Publishing each generation's payload into its own immutable
  # directory and naming that directory from +generation.json+ makes the single
  # atomic write of that one file the commit point for the whole payload.
  #
  # The reader half resolves the pointer ({Woods::MCP::IndexReader#payload_dir});
  # this is the half that builds what it points at.
  #
  # @example Publishing a generation
  #   payloads = Woods::PayloadStore.new(output_dir)
  #   dir = payloads.create(next_generation)
  #   payloads.clone(payloads.path_for(current_generation), dir)  # incremental
  #   # ... write the run's changes into `dir` ...
  #   generation.bump!(reason: 'incremental', payload: Woods::PayloadStore.name_for(next_generation))
  #   payloads.prune(keep: 3, protect: next_generation)
  #
  # Keep publication and retention under one payload owner.
  class PayloadStore # rubocop:disable Metrics/ClassLength
    DIRNAME = 'payloads'

    # How many payload generations to retain, overridable per host via
    # WOODS_PAYLOAD_RETENTION (read by Extractor#payload_retention). Three is
    # the current generation plus two a pinned reader might still be inside.
    DEFAULT_RETENTION = 3

    # @param output_dir [String, Pathname] index output directory
    def initialize(output_dir)
      @root = Pathname.new(output_dir.to_s)
    end

    # @return [Pathname] the directory holding every generation's payload
    def root
      @root.join(DIRNAME)
    end

    # The pointer a {Woods::Generation} carries for a generation's payload.
    #
    # Relative to the output directory by contract: the reader resolves it
    # against its own index root, which is not the absolute path the writer
    # used whenever the index is read through a volume mount.
    #
    # @param number [Integer] generation number
    # @return [String]
    def self.name_for(number)
      "#{DIRNAME}/gen-#{number}"
    end

    # @param number [Integer] generation number
    # @return [Pathname] where that generation's payload lives (may not exist)
    def path_for(number)
      @root.join(self.class.name_for(number))
    end

    extend Forwardable

    # Pin/unpin return whether persistent state changed. Pins are sorted
    # positive generation numbers, scoped to this index and retained on disk.
    def_delegators :generation_pins, :pin, :unpin, :pins

    # Create the payload directory for a generation and return it.
    #
    # An existing directory is **emptied** rather than reused. It can only be
    # there because an earlier run built a payload and then failed before
    # bumping the generation — nothing points at it, and merging this run's
    # files into that run's leftovers publishes a mixture of the two.
    # Persistently pinned destinations are refused, including counter resets.
    #
    # @param number [Integer] generation number this payload will be published as
    # @return [Pathname]
    def create(number)
      replace_unpinned(number) { |dir| FileUtils.mkdir_p(dir.to_s) }
    end

    # Correct a staged payload's number without replacing persistent pins.
    # @return [Pathname] the destination
    def rename(source, number)
      replace_unpinned(number, source: source) { |dir| FileUtils.mv(source.to_s, dir.to_s) }
    end

    # Populate +target+ with the contents of +source+ using hardlinks.
    #
    # This is what makes publishing a whole payload per generation affordable
    # on an incremental run: an unchanged file costs a directory entry rather
    # than a copy.
    #
    # It is safe **only because every writer against a payload goes through
    # {Woods::AtomicFile}**, which renames a fresh tempfile over the path. A
    # rename replaces the directory entry and leaves the old inode alone, so
    # the previous generation keeps its bytes. A bare +File.write+ to a cloned
    # path would edit the inode both generations share and corrupt the one a
    # reader is still pinned to.
    #
    # A missing source is a no-op — the first payload has nothing to clone.
    #
    # @param source [Pathname, String] the previous generation's payload
    # @param target [Pathname, String] a directory returned by {#create}
    # @return [void]
    def clone(source, target)
      from = File.expand_path(source.to_s)
      return unless File.directory?(from)

      to = target.to_s
      FileUtils.mkdir_p(to)
      pending = [[from, to]]
      until pending.empty?
        source_dir, target_dir = pending.pop
        Dir.each_child(source_dir) do |name|
          entry = File.join(source_dir, name)
          destination = File.join(target_dir, name)
          replicate(entry, destination, pending)
        end
      end
    end

    # Remove superseded payload directories, newest-first.
    #
    # +protect+ is never removed however the count works out: it is the
    # generation +generation.json+ names, and removing it would leave every
    # reader resolving a stale pointer back to the flat root.
    #
    # A directory numbered ABOVE +protect+ cannot be a generation still
    # ahead of us in a legitimate history — the counter only advances by
    # bumping past the currently published number — so it can only be a
    # leftover from before `generation.json` was lost and the counter
    # restarted lower. `sort.last(keep)` would otherwise read those stale
    # high numbers as "newest" and retain them forever while pruning the
    # genuinely-previous generation, so unpinned ones are removed regardless
    # of +keep+; ordinary retention then applies only to +protect+ and
    # below.
    #
    # Directories that do not parse as a generation payload are left alone —
    # retention only owns what it created.
    #
    # @param keep [Integer] how many payload generations to retain
    # @param protect [Integer] the currently published generation number
    # A reader pins a payload by holding a shared advisory lock on its
    # +manifest.json+. Retention takes the same file's exclusive lock without
    # waiting and skips the generation when another process is still reading
    # it. The operating system releases the shared lock if a reader crashes,
    # so there are no PID leases to expire and no stale marker to guess at.
    # The next publish retries every skipped generation normally.
    #
    # The manifest is the lock target rather than a reader-created sidecar so
    # the Index MCP remains a read-only consumer and payloads written before
    # this protocol remain protectable. Each published generation has its own
    # manifest inode: writers replace a cloned manifest through AtomicFile
    # before publishing, preserving generation-local lock identity.
    #
    # Persistent pins survive process exits and are retained in addition to
    # the recent-generation budget. Yields skipped number and :persistent_pin.
    # @return [Array<Integer>] the generation numbers removed
    def prune(keep:, protect:, &on_skip)
      return [] unless root.directory?

      generation_pins.synchronize do |pins|
        remove_generation_dirs(retention_candidates(keep, protect), pins: pins, &on_skip)
      end
    end

    # Hardlink where the filesystem allows it, copy where it does not — a
    # payload spanning a device boundary (a bind mount inside the output
    # directory) must still publish, just without the saving.
    #
    # Public so a caller seeding a payload from something other than
    # {#clone} — {Woods::Extractor#seed_payload_from_flat_root}, which walks
    # an allowlist of flat-root entries rather than a whole directory tree —
    # gets the same cross-device fallback. A bare +FileUtils.ln+ there raised
    # on every run on a filesystem that disallows hardlinks (e.g. some
    # overlay/bind-mount setups), degrading every run to a flat publish and
    # never once giving the fallback a chance to run.
    #
    # @param source [Pathname, String] file to link or copy
    # @param destination [Pathname, String] where it should land
    # @return [void]
    def link_or_copy(source, destination)
      File.link(source.to_s, destination.to_s)
    rescue Errno::EXDEV, Errno::EPERM, Errno::EMLINK, NotImplementedError
      FileUtils.cp(source.to_s, destination.to_s)
    end

    private

    def replace_unpinned(number, source: nil)
      dir = path_for(number)
      FileUtils.mkdir_p(@root)
      generation_pins.synchronize do |pins|
        protected_paths = pins.map { |pin| path_for(pin).expand_path }
        if pins.include?(number) || (source && protected_paths.include?(Pathname.new(source).expand_path))
          raise IOError, 'Cannot replace or move a persistently pinned generation'
        end

        FileUtils.rm_rf(dir.to_s)
        yield dir
      end
      dir
    end

    def generation_pins
      @generation_pins ||= GenerationPins.new(@root)
    end

    def retention_candidates(keep, protect)
      eligible, superseded = generation_dirs.partition { |number, _| number <= protect }
      retained = eligible.map(&:first).sort.last(keep)
      prunable = eligible.reject { |number, _| number == protect || retained.include?(number) }
      superseded + prunable
    end

    # @param pairs [Array<Array(Integer, Pathname)>]
    # @return [Array<Integer>] the generation numbers removed
    def remove_generation_dirs(pairs, pins:)
      pairs.filter_map do |number, dir|
        if pins.include?(number)
          yield number, :persistent_pin if block_given?
          next
        end
        remove_generation_dir(number, dir)
      end
    end

    # @return [Integer, nil] the removed generation, or nil while pinned
    def remove_generation_dir(number, dir)
      manifest = dir.join('manifest.json')
      return remove_unlocked_generation(number, dir) unless manifest.file?

      File.open(manifest.to_s, File::RDONLY) do |file|
        return nil unless file.flock(File::LOCK_EX | File::LOCK_NB)

        remove_unlocked_generation(number, dir)
      end
    rescue Errno::ENOENT
      # An incomplete/orphaned payload has no readable contract a reader can
      # pin. Retention still owns and may remove that directory.
      remove_unlocked_generation(number, dir)
    end

    # @return [Integer]
    def remove_unlocked_generation(number, dir)
      FileUtils.rm_rf(dir.to_s)
      number
    end

    # @return [Array<Array(Integer, Pathname)>]
    def generation_dirs
      root.children.filter_map do |child|
        match = child.directory? ? child.basename.to_s.match(/\Agen-(\d+)\z/) : nil
        [match[1].to_i, child] if match
      end
    end

    # Classify once: Find.find followed by File.directory? queried metadata
    # twice per file, costly on FUSE/virtiofs mounts. Parents are created before
    # their children, so regular files need no extra parent-directory checks.
    # Preserve the old walk's symlink behavior: a directory symlink becomes an
    # empty directory, never a traversal into another tree or generation.
    #
    # @param entry [String] source entry
    # @param destination [String] where it belongs in the target
    # @param pending [Array] directories still to visit
    # @return [void]
    def replicate(entry, destination, pending)
      stat = File.lstat(entry)
      if stat.directory? || (stat.symlink? && File.directory?(entry))
        FileUtils.mkdir_p(destination)
        pending << [entry, destination] if stat.directory?
      else
        link_or_copy(entry, destination)
      end
    end
  end
end
