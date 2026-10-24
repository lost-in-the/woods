# frozen_string_literal: true

require 'set'

module Woods
  # External services the application calls (#814): a curated catalog of
  # client gems, each naming the service it reaches and the constants its
  # client code is called through.
  #
  # Two facts come from it, both pure functions of source text, so full and
  # incremental runs agree:
  #
  # - the Gemfile configuration unit's `metadata.external_services`: the
  #   services whose client gem the Gemfile declares for runtime (no group,
  #   `default` or `production`), each with its gems as evidence;
  # - `:external_service` dependency edges (`via: :service_call`) from units
  #   whose source calls a client constant (`Stripe::Charge.create`,
  #   `Aws::S3::Client.new`), whichever gems are installed.
  #
  # Only catalogued gems become services: an unknown gem publishes nothing,
  # and a generic HTTP client (Faraday, Net::HTTP) names no service. No
  # credential, URL or configuration value is read.
  module ExternalServices
    # name => category, the client gems that reach it, and the constants its
    # client code is called through (most specific first)
    CATALOG = {
      'Stripe' => { category: 'payments', gems: %w[stripe], constants: %w[Stripe] },
      'Braintree' => { category: 'payments', gems: %w[braintree], constants: %w[Braintree] },
      'PayPal' => { category: 'payments', gems: %w[paypal-checkout-sdk paypal-sdk-rest],
                    constants: %w[PayPal PayPalCheckoutSdk] },
      'Amazon S3' => { category: 'storage', gems: %w[aws-sdk-s3], constants: %w[Aws::S3] },
      'Amazon SQS' => { category: 'messaging', gems: %w[aws-sdk-sqs], constants: %w[Aws::SQS] },
      'Amazon SNS' => { category: 'messaging', gems: %w[aws-sdk-sns], constants: %w[Aws::SNS] },
      'Amazon SES' => { category: 'email', gems: %w[aws-sdk-ses aws-sdk-sesv2], constants: %w[Aws::SES Aws::SESV2] },
      'Google Cloud Storage' => { category: 'storage', gems: %w[google-cloud-storage],
                                  constants: %w[Google::Cloud::Storage] },
      'Azure Blob Storage' => { category: 'storage', gems: %w[azure-storage-blob],
                                constants: %w[Azure::Storage::Blob] },
      'Twilio' => { category: 'messaging', gems: %w[twilio-ruby], constants: %w[Twilio] },
      'SendGrid' => { category: 'email', gems: %w[sendgrid-ruby], constants: %w[SendGrid] },
      'Postmark' => { category: 'email', gems: %w[postmark postmark-rails], constants: %w[Postmark] },
      'Mailgun' => { category: 'email', gems: %w[mailgun-ruby], constants: %w[Mailgun] },
      'Slack' => { category: 'messaging', gems: %w[slack-ruby-client], constants: %w[Slack::Web] },
      'GitHub' => { category: 'api', gems: %w[octokit], constants: %w[Octokit] },
      'OpenAI' => { category: 'api', gems: %w[ruby-openai openai], constants: %w[OpenAI] },
      'Anthropic' => { category: 'api', gems: %w[anthropic], constants: %w[Anthropic] },
      'Algolia' => { category: 'search', gems: %w[algoliasearch algoliasearch-rails algolia], constants: %w[Algolia] },
      'Elasticsearch' => { category: 'search', gems: %w[elasticsearch searchkick],
                           constants: %w[Elasticsearch Searchkick] },
      'Pusher' => { category: 'messaging', gems: %w[pusher], constants: %w[Pusher] },
      'Sentry' => { category: 'monitoring', gems: %w[sentry-ruby sentry-rails], constants: %w[Sentry] },
      'Honeybadger' => { category: 'monitoring', gems: %w[honeybadger], constants: %w[Honeybadger] },
      'Bugsnag' => { category: 'monitoring', gems: %w[bugsnag], constants: %w[Bugsnag] },
      'Rollbar' => { category: 'monitoring', gems: %w[rollbar], constants: %w[Rollbar] },
      'Datadog' => { category: 'monitoring', gems: %w[datadog ddtrace dogstatsd-ruby], constants: %w[Datadog] },
      'New Relic' => { category: 'monitoring', gems: %w[newrelic_rpm], constants: %w[NewRelic] }
    }.freeze

    # Every client constant, longest first so `Aws::S3` wins over a shorter prefix.
    CONSTANTS = CATALOG.values.flat_map { |entry| entry[:constants] }.uniq.sort_by { |c| -c.length }.freeze
    # One pattern for all of them, capturing the constant called through.
    CALL_PATTERN = /(?<![\w:])(#{CONSTANTS.map { |c| Regexp.escape(c) }.join('|')})(?:::|\.)[A-Za-z_]/

    # Gemfile groups whose gems run with the application.
    RUNTIME_GROUPS = %w[default production].freeze

    module_function

    # The services whose client gem a Gemfile declares for runtime.
    #
    # @param gems [Array<Hash>] {Extractors::GemfileDeclarations} rows (name, groups)
    # @return [Array<Hash>] `{ name:, category:, gems: }`, sorted by name
    def from_gems(gems)
      runtime = Array(gems).select { |gem| runtime?(gem) }.map { |gem| (gem[:name] || gem['name']).to_s }
      services = CATALOG.filter_map do |name, entry|
        declared = entry[:gems] & runtime
        { name: name, category: entry[:category], gems: declared } if declared.any?
      end
      services.sort_by { |service| service[:name] }
    end

    # `:external_service` edges for the client constants a source calls, in
    # catalog order. One scan of the source finds every client constant used
    # as a namespace or a receiver (`Stripe::Charge`, `Stripe.api_key`, but
    # not `StripeCustomer` or `MyStripe`).
    #
    # @param source [String] a unit's source
    # @return [Array<Hash>] `{ type: :external_service, target:, via: :service_call }`
    def dependencies(source)
      return [] if source.nil? || source.empty?

      called = source.scan(CALL_PATTERN).flatten.to_set
      CATALOG.filter_map do |name, entry|
        { type: :external_service, target: name, via: :service_call } if entry[:constants].any? do |c|
          called.include?(c)
        end
      end
    end

    def runtime?(gem)
      groups = Array(gem[:groups] || gem['groups']).map(&:to_s)
      groups.empty? || (groups & RUNTIME_GROUPS).any?
    end
  end
end
