# frozen_string_literal: true

# The conventional ActiveJob base. Its presence turns on the job extractor's
# descendant walk, which is the only way a job nested in a non-job file is
# discovered (see app/models/billing/invoicing/reconciler.rb).
class ApplicationJob < ActiveJob::Base
end
