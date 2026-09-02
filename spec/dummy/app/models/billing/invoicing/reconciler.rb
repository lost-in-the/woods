# frozen_string_literal: true

# A job nested inside a compact-form, non-ActiveRecord model-directory class
# (finding N-1). The outer class indexes as a PORO. The nested job is found on
# the full path by the ApplicationJob descendant walk — never by the
# job-directory scan — and carries this file as its file_path. The incremental
# path used to re-derive it from the file, name the enclosing class, and
# register a second job unit under the PORO's identifier. The booted
# equivalence lane pins the two paths to the same index.
#
# The compact declaration is the shape under test, not a style choice.
class Billing::Invoicing::Reconciler # rubocop:disable Style/ClassAndModuleChildren
  class RefreshJob < ApplicationJob
    def perform
      Post.count
    end
  end
end
