# frozen_string_literal: true

require 'tempfile'
require 'open3'
require_relative 'plan'

module Woods
  module AgentConfiguration
    module PlanDiff
      def self.show(plan, output)
        plan.data.fetch('changes').each do |change|
          document = Document.new(change.fetch('path'))
          unless document.fingerprint == change.fetch('before')
            raise Conflict, "Changed since preview: #{document.path}; create a new plan before viewing its diff"
          end

          output.write(render(document, Plan.after_content(change)))
        end
      end

      def self.render(document, content)
        Tempfile.create('woods-config-before') do |before|
          Tempfile.create('woods-config-after') do |after|
            before.write(document.content.to_s)
            after.write(content.to_s)
            before.flush
            after.flush
            diff, status = Open3.capture2('diff', '-u', '--label', document.path, '--label', document.path,
                                          before.path, after.path)
            raise Conflict, 'Cannot render plan diff' unless [0, 1].include?(status.exitstatus)

            diff
          end
        end
      end
    end
  end
end
