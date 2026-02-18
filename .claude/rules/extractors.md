---
paths:
  - "lib/codebase_index/extractors/**/*.rb"
---
# Extractor Conventions

Every extractor follows this structure:

```ruby
module CodebaseIndex
  module Extractors
    class FooExtractor
      def initialize
        # Discover directories, validate Rails is loaded
      end

      def extract_all
        # Return Array<ExtractedUnit>
      end

      def extract_foo_file(file_path)
        # Return ExtractedUnit or nil (skip non-matching files)
      end
    end
  end
end
```

Rules:
- Always return `ExtractedUnit` instances, never raw hashes
- Set `unit.dependencies` as an array of `{ type:, target:, via: }` hashes
- Use `File.read` for source, never `eval` or `load`
- Runtime introspection (reflection APIs, `descendants`, route helpers) is preferred over parsing when available
- Handle missing directories gracefully — a host app may not have `app/interactors/`
- Inlining concerns: resolve `include FooConcern` by reading the concern source and appending it to `source_code`. Track inlined concerns in `metadata[:inlined_concerns]`
- YARD-document the class and all public methods
