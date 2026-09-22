# frozen_string_literal: true

module Woods
  module Watch
    class Installation
      # Replays only validated local transaction state; never discovers or boots Rails.
      class Recovery
        # @param root [String] selected canonical application directory
        def initialize(root:)
          @root = root
        end

        # @param pretend [Boolean] check journal and current snapshots without writes
        # @return [String] recovery status
        def call(pretend: false)
          journal = read_journal
          return 'nothing_to_recover' unless journal

          layout = recovery_layout(journal)
          applier = Woods::AgentConfiguration::Applier.new(layout: layout)
          return applier.recover unless pretend

          verify_preview(applier, layout, journal)
          'recovery_preview_verified'
        rescue KeyError, TypeError, ArgumentError => e
          raise Conflict, "Invalid watcher recovery journal: #{e.message}"
        end

        private

        def read_journal
          layout = Layout.new(@root, 'Procfile.dev')
          document = Woods::AgentConfiguration::Document.new("#{layout.receipt_path}.pending")
          document.content && document.json
        end

        def recovery_layout(journal)
          plan = journal.fetch('plan')
          identity = plan.fetch('layout')
          raise Conflict, 'Recovery journal belongs to another application' unless identity.fetch('root') == @root

          layout = Layout.new(@root, identity.fetch('procfile'))
          paths = plan.fetch('changes').map do |change|
            path = change.fetch('path')
            raise Conflict, 'Recovery target is outside the application' unless path.start_with?("#{@root}/")

            path.delete_prefix("#{@root}/")
          end
          layout.include_previous(paths)
          layout
        end

        def verify_preview(applier, layout, journal)
          plan = Woods::AgentConfiguration::Plan.allocate
          plan.instance_variable_set(:@data, journal.fetch('plan'))
          plan.validate!(layout)
          changes = plan.data.fetch('changes')
          applier.send(:validate_originals!, journal.fetch('originals'), changes)
          changes.each { |change| applier.send(:validate_recovery_snapshot!, change) }
        end
      end
    end
  end
end
