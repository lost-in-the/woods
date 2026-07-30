# frozen_string_literal: true

# Historical home of the deterministic fake embedding provider. The class
# was promoted into the gem proper as Woods::Embedding::Provider::Fake
# (lib/woods/embedding/fake.rb, #178) so `embedding_provider = :fake`
# works outside this suite — CI, sandboxes, offline hosts. This file is
# now a require-level re-point kept so spec_helper's support glob keeps
# every existing spec working unchanged. Do NOT add a second
# implementation here; specs and lib code must share the one class.
require 'woods/embedding/fake'
