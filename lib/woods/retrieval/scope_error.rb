# frozen_string_literal: true

module Woods
  module Retrieval
    class Scope
      # Raised for a malformed scope request (list shape, escaping path,
      # unknown package) and for a corpus that cannot back one (a missing or
      # duplicate record, a view requested over keys it does not hold).
      # Defined apart from {Scope} so {ScopeCorpus} can raise it without
      # loading the scope resolver.
      class InvalidScopeError < ArgumentError; end
    end
  end
end
