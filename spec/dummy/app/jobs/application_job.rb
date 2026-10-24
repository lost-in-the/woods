# frozen_string_literal: true

# The conventional ActiveJob base. Its presence turns on the job extractor's
# descendant walk, which is the only way a job nested in a non-job file is
# discovered (see app/models/billing/invoicing/reconciler.rb). Its retry_on is
# inherited by ResilientJob, which W-4 publishes as declared here.
class ApplicationJob < ActiveJob::Base
  retry_on Timeout::Error, wait: 5, attempts: 2
end
