# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

require_relative '../release'

module Woods
  module Release
    # Advisory checks for the three live prerequisites the beta1 dispatch
    # discovered by failing on them one at a time: an unprotected `release`
    # environment (release run 34409411101), a `REQUIRED_CI_JOBS` prefix left
    # behind by a ci.yml job rename (release run 34407589537), and a
    # download-artifact step missing `merge-multiple: true` (release run
    # 34409620040, see docs/CONTRIBUTING.md "When a dispatch fails").
    #
    # `release:prepare` runs this and prints the result before its tag and
    # dispatch commands. Every check is advisory: nothing here blocks a
    # prepare, and a check that needs `gh` skips with a note rather than
    # failing when `gh` is missing, unauthenticated, or offline.
    module Preflight
      CheckResult = Struct.new(:name, :status, :message, keyword_init: true)

      REPOSITORY = 'lost-in-the/woods'
      RELEASE_ENVIRONMENT = 'release'
      VALIDATOR_PATH = 'script/validate-release-run'
      CI_WORKFLOW_PATH = '.github/workflows/ci.yml'
      RELEASE_WORKFLOW_PATH = '.github/workflows/release.yml'
      REQUIRED_CI_JOBS_PATTERN = /REQUIRED_CI_JOBS = (\{.*?\})\.freeze/m

      module_function

      # @return [Array<CheckResult>]
      def run(root:)
        [
          check_environment_protection,
          check_required_ci_jobs(root),
          check_merge_multiple(root)
        ]
      end

      # @return [String] a human-readable report for release:prepare to print
      def report(root:)
        lines = run(root: root).map { |result| "  [#{result.status.to_s.upcase}] #{result.name}: #{result.message}" }
        "Preflight (advisory, does not block prepare):\n#{lines.join("\n")}\n"
      end

      # The same live check `script/validate-release-run` makes before a
      # publish is allowed to proceed, run early enough to fix before a tag
      # ever exists. Detection only: this cannot and does not change the
      # live environment's settings.
      #
      # @api private
      # @return [CheckResult]
      def check_environment_protection(env: {})
        stdout, stderr, status = Open3.capture3(
          env, 'gh', 'api', '--method', 'GET', "repos/#{REPOSITORY}/environments/#{RELEASE_ENVIRONMENT}"
        )
        return skipped('release environment protection', "gh api failed: #{stderr.strip}") unless status.success?

        environment_protection_result(JSON.parse(stdout))
      rescue Errno::ENOENT
        skipped('release environment protection', 'gh is not installed')
      rescue JSON::ParserError => e
        skipped('release environment protection', "gh returned invalid JSON: #{e.message}")
      end

      def environment_protection_result(environment)
        if environment.fetch('protection_rules', []).empty?
          warning('release environment protection',
                  "live '#{RELEASE_ENVIRONMENT}' environment has no protection rules configured")
        elsif environment.fetch('can_admins_bypass', false)
          warning('release environment protection',
                  "live '#{RELEASE_ENVIRONMENT}' environment allows administrators to bypass protection rules")
        else
          ok('release environment protection', 'required reviewers configured, admin bypass disabled')
        end
      end

      # `script/validate-release-run` names the CI jobs a candidate must have
      # passed by job id and name prefix. A rename in ci.yml without a
      # matching update there fails release-context after the tag is
      # pushed, when moving the tag is the only fix left (see the
      # `spec/release_v2/ci_contract_job_names_spec.rb` contract this
      # mirrors, run here without needing the network).
      #
      # @api private
      # @return [CheckResult]
      def check_required_ci_jobs(root)
        required_jobs = required_ci_jobs(root)
        ci_jobs = YAML.safe_load_file(File.join(root, CI_WORKFLOW_PATH), aliases: true).fetch('jobs')
        missing = required_jobs.keys.reject { |job_id| ci_jobs.key?(job_id) }
        mismatched = (required_jobs.keys - missing).reject do |job_id|
          static_job_name(ci_jobs.fetch(job_id), job_id).start_with?(required_jobs.fetch(job_id))
        end

        required_ci_jobs_result(required_jobs, missing, mismatched)
      end

      def required_ci_jobs_result(required_jobs, missing, mismatched)
        if missing.empty? && mismatched.empty?
          ok('REQUIRED_CI_JOBS matches ci.yml', "#{required_jobs.length} required jobs present with matching prefixes")
        else
          warning('REQUIRED_CI_JOBS matches ci.yml',
                  "missing from ci.yml: #{missing.join(', ')}; prefix mismatch: #{mismatched.join(', ')}".strip)
        end
      end

      def static_job_name(job, job_id)
        (job['name'] || job_id).to_s.split('${{').first.to_s
      end

      def required_ci_jobs(root)
        source = File.read(File.join(root, VALIDATOR_PATH), encoding: Encoding::UTF_8)
        literal = source[REQUIRED_CI_JOBS_PATTERN, 1]
        raise "REQUIRED_CI_JOBS not found in #{VALIDATOR_PATH}" unless literal

        eval(literal) # rubocop:disable Security/Eval -- trusted repo source, mirrors ci_contract_job_names_spec.rb
      end

      # download-artifact v4 extracts an artifact-ids download into
      # path/<artifact-name>/ unless merge-multiple is set, which is exactly
      # what broke release run 34409620040 in both the package-test and
      # publish jobs.
      #
      # @api private
      # @return [CheckResult]
      def check_merge_multiple(root)
        release = YAML.safe_load_file(File.join(root, RELEASE_WORKFLOW_PATH), aliases: true)
        offenders = download_steps(release).reject { |_job_name, step| step.dig('with', 'merge-multiple') == true }

        if offenders.empty?
          ok('download-artifact merge-multiple', 'every download-artifact step sets merge-multiple: true')
        else
          warning('download-artifact merge-multiple',
                  "missing merge-multiple: true in job(s): #{offenders.map(&:first).uniq.join(', ')}")
        end
      end

      def download_steps(release)
        release.fetch('jobs').flat_map do |job_name, job|
          job.fetch('steps', [])
             .select { |step| step.fetch('uses', '').start_with?('actions/download-artifact@') }
             .map { |step| [job_name, step] }
        end
      end

      def ok(name, message)
        CheckResult.new(name: name, status: :ok, message: message)
      end

      def warning(name, message)
        CheckResult.new(name: name, status: :warning, message: message)
      end

      def skipped(name, message)
        CheckResult.new(name: name, status: :skipped, message: message)
      end
    end
  end
end
