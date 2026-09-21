# Rails Reviewer Question Bank (Jev)

2026-09-19 · @Someone

## Purpose and how to read the results

One Jev request per code change, every question below sent together. Each reviewer has one **headline Score** and a list of **finding Nouls**. The Score is the reviewer's bar on the comparison chart: it is calibrated, has a confidence value, and rates impact on a described spectrum. The Nouls are the itemized reasons underneath the bar. Nothing here decides anything; a human or agent reads the chart afterwards.

Conventions:

- Question text is the literal `instructions` string. IDs are suggested; they are not sent to the model.
- **Noul** is the default. It returns the probability that the answer is yes, so every question reads as "probability this is a problem" and bars are comparable across reviewers.
- **Score** is used only where a spectrum matters. Normalize by top level before charting.
- **(ctx: …)** marks what must be packed into the state beyond the diff. Everything else runs on the diff plus the touched files.
- Questions are evaluated independently. Two questions that overlap will double-count in a reviewer's mean; that is a wording bug to fix during calibration, not a feature.
- Some questions overlap with RuboCop, Bullet, Prosopite, Brakeman or strong\_migrations. They stay in on purpose: agreement is free validation data, disagreement tells you which side is wrong.

State budget: 32k tokens for state plus the longest question. Pack what the ctx notes ask for and nothing else.

**Direction and kind.** Every Noul is yes-is-bad and every Score is higher-is-worse unless listed here. Exceptions: `test_regression_for_fix` (yes is good), `test_coverage_of_change` (higher is better). Choices are unordered. The runner reads direction from this list; it never treats a normalized value as defect risk on its own. Each question is also one of three kinds — **fact** (a pattern is present), **defect** (a supported mechanism can fail), or **convention** (a project preference) — and the chart weights them differently. Rows are defects unless the section source line says otherwise; the Batsov, Views, and Codebase sections are mostly conventions, and `change_kind`, `primary_concern`, and the `test_*` structure questions are facts.

**Headline mapping.** One Score per reviewer is the bar: DHH `dhh_conformance`, Views `view_logic_placement`, Metz `metz_blast_radius`, Tests `test_coverage_of_change`, Berkopec `perf_impact`, Uchitelle `db_migration_risk`, Batsov `ar_persistence_risk`, Avdi `avdi_return_contract`, tenderlove `vm_memory_impact`, Security `sec_worst_case_impact`, Perham `job_failure_impact`, Observability `obs_debuggability`, Codebase `repo_fit`, Rollout `rollout_behavior_change_scope` (with `rollout_user_visibility` as a second, unweighted bar), Blast `blast_data_reach`. Change hygiene has no bar; its three Choices route.

## DHH — is this fighting Rails?

Source: Rails Doctrine, *Getting Real*, the "Majestic Monolith" and "vanilla Rails" posts. Lens: convention over configuration, conceptual compression, ceremony is a cost.

| ID | Type | Question |
| --- | --- | --- |
| `dhh_conformance` | Score | How closely does this follow Rails conventions? — 0 idiomatic Rails · 1 one detour with a reason · 2 a parallel abstraction beside the framework · 3 bypasses the framework |
| `dhh_unneeded_abstraction` | Noul | Does the change add a service object, form object, decorator, or wrapper where a model method, concern, scope, or callback would do the same job? |
| `dhh_reimplements_rails` | Noul | Does the change reimplement behavior that Rails or ActiveSupport already provides? |
| `dhh_pattern_indirection` | Noul | Does the change add indirection or configuration that serves a design pattern rather than a stated requirement? |
| `dhh_gem_for_builtin` | Noul | Does the change add a gem for something Rails ships with (auth, jobs, caching, file storage, websockets)? |
| `dhh_tests_the_framework` | Noul | Does the change add tests that only exercise Rails behavior rather than the application's own logic? |
| `dhh_speculative_generality` | Noul | Does the change add an option, argument, hook, or configuration point that nothing in the diff uses? |
| `ctrl_business_logic` | Noul | Does a controller action contain business logic, or instantiate or call more than one domain object beyond the initial find or new? |
| `ctrl_non_restful_action` | Noul | Does the change add a controller action outside the seven RESTful actions where a new resource would express it? |
| `ctrl_filter_for_inherited_action` | Noul | Does the change add a `before_action` with `only:` or `except:` naming an action defined in a parent class? |
| `dep_unvetted_gem` | Noul | **(ctx: Gemfile diff)** Does the change add a gem with no stated reason, or a little-known gem for something a well-established one already does? |

## Views and Hotwire — DHH, the HTML-over-the-wire half

Source: thoughtbot Rails guide, Rails style guide, Hotwire handbook and pattern guides. Kept separate from the framework-conformance section so each bar measures one thing. Runs on views, partials, helpers, components, and Stimulus controllers in the diff.

| ID | Type | Question |
| --- | --- | --- |
| `view_logic_placement` | Score | Where does the display logic in this change live? — 0 markup only, logic on the server · 1 light formatting in a helper, presenter, or component · 2 conditionals or queries in the template · 3 business logic in the template or in JavaScript |
| `view_queries_model` | Noul | Does a view or partial call a model class or run a query? |
| `view_instance_var_in_partial` | Noul | Does a partial read an instance variable instead of a local? |
| `view_business_logic` | Noul | Does a view contain calculations, multi-branch conditionals, or non-display logic? |
| `view_helper_returns_html` | Noul | Does a helper build HTML with string concatenation or `content_tag` chains where a partial or component would do? |
| `view_link_for_non_get` | Noul | Does the change use `link_to` for a non-GET action? |
| `view_broadcast_unscoped` | Noul | Does a Turbo Stream broadcast go to a channel that viewers without authorization could subscribe to? |
| `view_stimulus_business_logic` | Noul | Does a Stimulus controller contain application logic or state that belongs on the server? |
| `view_requires_js` | Noul | Does the change add a form or link that does nothing without JavaScript? |
| `view_turbo_frame_mismatch` | Noul | Does a Turbo Frame response render a frame id that does not match the request? |
| `view_no_strict_locals` | Noul | **(ctx: siblings)** Does a new partial omit a strict locals declaration where sibling partials use one? |
| `view_missing_a11y_basics` | Noul | Does new markup add a form field without a label, an image without alt text, or an interactive element without a keyboard path? |

## Sandi Metz — will this hurt when it changes?

Source: *POODR* ch. 2–8, *99 Bottles of OOP*, "The Wrong Abstraction". Lens: dependency direction, message-based design, cost of change.

| ID | Type | Question |
| --- | --- | --- |
| `metz_blast_radius` | Score | How many places would need to change for one plausible requirement change to this feature? — 0 one file · 1 a few related files · 2 across layers · 3 across a public API or schema boundary |
| `metz_depends_on_volatile` | Noul | **(ctx:** Woods volatile\_dependencies report: 365-day commit counts, configured ratio with default 3.0, dependencies under 5 commits skipped) Does the changed code depend on a unit the report lists as changing materially more often than the changed code itself? |
| `metz_hardcoded_collaborator` | Noul | Does the change hard-code a collaborator by constant reference or `.new` where it could be passed in? |
| `metz_branches_on_type` | Noul | Does the change branch on an object's class, type, or a role flag? |
| `metz_reaches_through` | Noul | Does a changed method reach through more than one object to get what it needs? |
| `metz_premature_abstraction` | Noul | Does the change extract a shared abstraction from fewer than three real call sites? |
| `metz_missed_duplication` | Noul | **(ctx: grep hits for similar code)** Does the change duplicate logic that already exists elsewhere in the codebase? |
| `metz_argument_order` | Noul | Does a changed method take three or more positional arguments? |
| `metz_asks_instead_of_tells` | Noul | Does the change query an object's state and then decide what to do with it, where the object could make that decision itself? |
| `metz_feature_envy` | Noul | Does a changed method use another object's data or methods more than its own? |
| `metz_concern_not_cohesive` | Noul | Does the change add a concern or mixin that is included in only one class, or that carries its own state? |
| `metz_new_sti_type` | Noul | Does the change add a Single Table Inheritance subclass or a type column that selects behavior? |
| `metz_model_formats_output` | Noul | Does the change add a method to a model that only formats data for display? |

Note: `premature_abstraction` and `missed_duplication` are deliberately two Nouls, not one Score. Both ends of the abstraction spectrum are bad and a Score cannot express a U-shape.

## Sandi Metz — tests

Source: *POODR* ch. 9, "Magic Tricks of Testing"; Justin Searls (*How to Stop Hating Your Tests*, *Please Don't Mock Me*); Vladimir Dementyev and Evil Martians (TestProf, flaky-test series). Lens: test incoming messages for state, outgoing commands for being sent, nothing else; and a test suite is a design signal and a feedback loop, not a ritual. Runs on the test files in the diff.

| ID | Type | Question |
| --- | --- | --- |
| `test_coverage_of_change` | Score | How well do the tests in the diff cover the behavior the diff changes? — 0 no tests touched · 1 tests touched but not the changed behavior · 2 changed behavior covered on the happy path · 3 changed behavior and its edge cases covered |
| `test_private_method` | Noul | Does a test call or stub a private method? |
| `test_asserts_internals` | Noul | Does a test assert on an object's internal state or instance variables rather than its public return values? |
| `test_query_message_stubbed` | Noul | Does a test verify that a query message was sent, rather than testing its return value? |
| `test_brittle_to_refactor` | Noul | Would a test in the diff break if the implementation were refactored without changing behavior? |
| `test_time_dependent` | Noul | Does a test depend on the current time or date without freezing it? |
| `test_order_dependent` | Noul | Does a test depend on records or state created by another test? |
| `test_duplicates_setup` | Noul | Does the test repeat setup that a factory, fixture, or shared context already provides? |
| `test_regression_for_fix` | Noul | **(ctx: `change_kind` = fix)** Does a bug fix include a test that would have failed before the fix? |
| `test_multiple_behaviors` | Noul | Does a single test verify more than one behavior, or lack a clear setup / action / assertion shape? |
| `test_cannot_fail` | Noul | Does a test have no assertion, or an assertion that would pass regardless of the code under test? |
| `test_mocks_unowned` | Noul | Does a test mock or stub a third-party library, the database, or the framework rather than the application's own collaborator? |
| `test_partial_mock` | Noul | Does a test stub a method on the real object under test? |
| `test_conditional_logic` | Noul | Does a test contain `if`, loops, or rescue that change what it asserts? |
| `test_name_describes_implementation` | Noul | Does a test name describe how the code works rather than what it should do? |
| `test_factory_cascade` | Noul | Does a test use `create` with associations where `build`, `build_stubbed`, or attributes would do? |
| `test_shared_state_mutated` | Noul | Does a test mutate a record created in `before(:all)`, `let_it_be`, or a fixture that other tests read? |
| `test_jobs_inline` | Noul | Does a test run background jobs inline when the test does not assert on their effect? |
| `test_sleep` | Noul | Does a test call `sleep` or poll with a fixed delay instead of waiting on a condition? |
| `test_live_external_call` | Noul | Does a test hit a real external service, or rely on a recorded cassette that can drift? |
| `test_time_not_restored` | Noul | Does a test travel or freeze time without a matching return? |
| `test_system_where_request_would_do` | Noul | Does the change add a browser or system test for behavior a request or unit test could cover? |
| `test_hidden_setup` | Noul | Does a test depend on setup in a support file, shared context, or `spec_helper` that is not visible from the test? |
| `test_ddl_uncleaned` | Noul | Does a test create tables, columns, or other DDL that a transaction will not roll back? |
| `test_travel_to_now` | Noul | Does a test call `travel_to` with the current time instead of `freeze_time`? |

## Nate Berkopec — will this be slow, and do we know?

Source: *The Complete Guide to Rails Performance*, Speedshop blog. Lens: measure before optimizing, the database is usually the problem, the request path is sacred.

| ID | Type | Question |
| --- | --- | --- |
| `perf_impact` | Score | How much will this change cost a typical request or job at production scale? — 0 no measurable cost · 1 cheap in-process work · 2 one or more extra queries or an external call · 3 cost grows with data size (per-record queries, unbounded loads) |
| `perf_n_plus_one` | Noul | Does the change iterate over an ActiveRecord relation and call an association inside the loop without preloading? |
| `perf_query_in_loop` | Noul | Does the change run a query inside a loop, partial, or serializer? |
| `perf_loads_full_records` | Noul | Does the change load full records where `pluck`, `select`, `exists?`, or `count` would do? |
| `perf_request_path_work` | Noul | Does the change add work to the request path (email, HTTP call, file processing, report generation) that could run in a background job? |
| `perf_unmeasured_optimization` | Noul | Does the change add caching, memoization, or raw SQL without a stated measurement justifying it? |
| `perf_missing_index` | Noul | **(ctx: schema.rb)** Does the change query, join, or sort on a column with no index? |
| `perf_cache_without_invalidation` | Noul | Does the change add a cache read without a clear key expiry or invalidation path? |
| `perf_synchronous_external_call` | Noul | Does the change make an external HTTP call without a timeout? |
| `perf_counts_in_view` | Noul | Does the change call `.count` or `.size` on an unloaded relation inside a view or loop? |
| `perf_benchmark_not_shared` | Noul | **(ctx: PR description)** Does a performance-motivated change omit the benchmark script and results? |

## Eileen Uchitelle — will this break the database?

Source: Rails core work on multi-DB, connection handling, and upgrades; Andrew Kane's strong\_migrations for the migration rules. Lens: the database outlives the code, constraints belong in the schema.

| ID | Type | Question |
| --- | --- | --- |
| `db_migration_risk` | Score | How risky is the migration in this change on a large production table? — 0 no migration, or additive and non-locking · 1 safe with care (needs `algorithm: :concurrently`, batching, or a two-step deploy) · 2 takes a lock or rewrites the table · 3 loses or corrupts data if it fails partway or is reverted |
| `db_transaction_across_io` | Noul | Does the change hold a transaction or connection open across an external call, sleep, or job enqueue? |
| `db_writes_not_atomic` | Noul | Does the change perform multiple writes that must succeed together outside a transaction? |
| `db_validation_without_constraint` | Noul | Does the change add a model validation (presence, uniqueness, foreign key) with no matching database constraint or index? |
| `db_adapter_specific` | Noul | Does the change depend on ActiveRecord behavior that differs by database adapter or Rails version? |
| `db_assumes_single_writer` | Noul | **(ctx: database.yml)** Does the change assume a single writer where multiple databases or replicas are configured? |
| `db_migration_with_data` | Noul | Does a migration modify data in the same migration that changes the schema? |
| `db_irreversible_migration` | Noul | Does a migration lack a working `down` or use `change` for an operation ActiveRecord cannot reverse? |
| `db_default_in_code_only` | Noul | Does the change set a default value in Ruby that should be a column default? |

## Bozhidar Batsov — Rails style guide semantics

Source: the community Rails style guide and rubocop-rails, plus the thoughtbot Rails guide. Nearly every row has a cop. They stay in because the cop fires on syntax and the question asks whether the shortcut was intended; cop-versus-Jev disagreement is the calibration signal.

| ID | Type | Question |
| --- | --- | --- |
| `ar_persistence_risk` | Score | How likely is this change to persist data the model layer would have rejected, or that the caller does not expect? — 0 every write goes through a validated, checked path · 1 a bypass or unchecked write that is clearly intentional and low-stakes · 2 a bypass or unchecked write on an ordinary record · 3 a bypass or unchecked write on a shared, financial, or user-visible record |
| `ar_skips_validations` | Noul | Does the change persist with a method that skips `Active Record validations (update_attribute, toggle!, increment!, save(validate: false)) or skips both validations and callbacks (update_columns, update_all, touch, update_counters) where the skip is not clearly intended? Plain toggle does not persist.` |
| `ar_unchecked_save` | Noul | Does the change call `save`, `create`, `update`, or `destroy` without the bang form and without checking the return value? |
| `ar_callback_halts_silently` | Noul | Does a callback return `false` or `throw :abort` in a way the caller will not notice? |
| `ar_before_destroy_not_prepended` | Noul | Does the change add a `before_destroy` guard on a model with `dependent: :destroy` associations without `prepend: true`? |
| `ar_association_without_dependent` | Noul | Does the change add a `has_many` or `has_one` with no `dependent` option? |
| `ar_reference_without_fk` | Noul | Does a migration add a reference or `_id` column without a foreign key constraint, or a foreign key without an `on_delete` decision? |
| `ar_nullable_boolean` | Noul | Does a migration add a boolean column without `null: false` and a default? |
| `ar_default_scope` | Noul | Does the change add or widen a `default_scope`? |
| `ar_enum_by_array` | Noul | Does the change define an enum with an array instead of an explicit hash? |
| `ar_order_by_id` | Noul | Does the change order records by `id` to mean chronological? |
| `ar_where_not_multi` | Noul | Does the change call `where.not` with more than one attribute? |
| `ar_find_by_memoized` | Noul | Does the change memoize a `find_by` or other nil-returning call with the or-equals operator, so a nil result is never cached? |
| `ar_ignored_columns_overwrite` | Noul | Does the change assign `ignored_columns` with `=` instead of `+=`? |
| `ar_after_commit_collision` | Noul | Does the change register two `after_*_commit` callbacks with the same method name on one model? |
| `ar_migration_uses_app_model` | Noul | Does a migration reference an application model class instead of a local class or SQL? |
| `ar_sql_outside_model` | Noul | Does the change put a SQL fragment in a controller, view, job, or helper? |
| `ar_validates_id_not_object` | Noul | Does the change validate a `_id` column instead of the associated object? |
| `time_zone_unaware` | Noul | Does the change use `Time.now`, `Date.today`, `Time.parse`, or `String#to_time` where zone-aware equivalents exist? |
| `env_unchecked` | Noul | Does the change read `ENV[]` without `fetch` or a default, or branch on `Rails.env` in application code? |
| `mailer_path_helper` | Noul | Does a mailer view or a redirect use a `_path` helper instead of `_url`? |
| `i18n_hardcoded_string` | Noul | **(ctx: whether the app uses locales)** Does the change hard-code user-facing text where the surrounding code uses `t()`? |

## Avdi Grimm — can this method be trusted?

Source: *Confident Ruby*, *Exceptional Ruby*. Lens: collect input, perform work, deliver output, handle failure — in that order; nil is not a value.

| ID | Type | Question |
| --- | --- | --- |
| `avdi_return_contract` | Score | How reliably can a caller trust what the changed methods return? — 0 every path returns the same documented type · 1 nil on rare or documented paths · 2 mixed types or nil on ordinary paths · 3 raises or returns garbage on paths the caller would not expect |
| `avdi_nil_on_some_paths` | Noul | Does any changed method return nil on some paths and a value on others? |
| `avdi_unguarded_input` | Noul | Does any changed method use an argument without validating or coercing it at the boundary? |
| `avdi_swallowed_rescue` | Noul | Does a rescue swallow an error without re-raising, logging, or returning a meaningful result? |
| `avdi_nil_as_domain_state` | Noul | Does the change use nil to mean a real domain state such as missing, empty, unknown, or not-yet-loaded? |
| `avdi_interleaved_checks` | Noul | Does a changed method interleave input checking and error handling with its core logic instead of handling them up front? |
| `avdi_rescue_too_broad` | Noul | Does the change rescue `Exception` or `StandardError` where a specific error class is available? |
| `avdi_boolean_return_ambiguous` | Noul | Does a changed method return a boolean from some paths and an object or nil from others? |
| `avdi_exception_for_control_flow` | Noul | Does the change raise and rescue an exception to control normal program flow? |
| `api_success_with_error` | Noul | Does the change return a 2xx status with an error in the body? |
| `ext_call_no_failure_handling` | Noul | Does the change call an external service without handling its failure, timeout, or malformed response? |

## tenderlove — what does this cost the VM?

Source: Aaron Patterson's talks and blog on allocation, GC, and ActiveRecord internals. Lens: objects are not free, memory bloat is a slow leak.

| ID | Type | Question |
| --- | --- | --- |
| `vm_memory_impact` | Score | What does this change do to process memory over time? — 0 nothing beyond normal per-request garbage · 1 more per-request garbage, collected normally · 2 retains objects across requests, bounded · 3 retains objects without bound, or loads unbounded collections |
| `vm_hot_loop_allocation` | Noul | Does the change allocate new strings, arrays, or hashes inside a loop where a single pass or mutation would do? |
| `vm_unbatched_collection` | Noul | Does the change load a whole collection into memory instead of batching with `find_each` or `in_batches`? |
| `vm_dynamic_definition_on_request` | Noul | Does the change define methods, constants, or classes dynamically on the request path? |
| `vm_memoization_retains` | Noul | Does the change memoize something at class or process level that could retain large objects across requests? |
| `vm_string_building` | Noul | Does the change build a string with repeated `+` or interpolation in a loop instead of `<<` or `join`? |
| `vm_large_object_in_session` | Noul | Does the change store an object graph, record, or large structure in the session or cookie? |
| `vm_unfrozen_constant` | Noul | Does the change define a mutable constant (array, hash, string) without freezing it? |
| `vm_needless_dup` | Noul | Does the change call `dup`, `to_a`, `map`, or `flatten` on a collection that is immediately iterated once? |

## Security — Justin Collins / Rails Security Guide

Source: Brakeman (Justin Collins), the official Rails Security Guide, OWASP Top 10. Lens: every input is hostile, every record lookup needs an owner, every dynamic dispatch is an injection point. Brakeman covers some of these statically; the rest need semantics.

| ID | Type | Question |
| --- | --- | --- |
| `sec_worst_case_impact` | Score | If the riskiest thing in this change were exploited, what happens? — 0 nothing exploitable · 1 a user affects only their own data or session · 2 a user reads or changes another user's or account's data · 3 code execution, credential exposure, or access to all data |
| `sec_sql_interpolation` | Noul | Does the change build SQL with string interpolation or `#{}` instead of bind parameters or Arel? |
| `sec_unscoped_lookup` | Noul | Does the change find a record by an ID from params without scoping it to the current user, account, or tenant? |
| `sec_missing_authorization` | Noul | Does the change add or modify a controller action without an authorization check? |
| `sec_mass_assignment` | Noul | Does the change permit params broadly (`permit!`, permitting `id`, `role`, `admin`, or foreign keys) or bypass strong parameters? |
| `sec_dynamic_dispatch_on_input` | Noul | Does the change call `send`, `constantize`, `eval`, `instance_variable_set`, or `public_send` with a value derived from user input? |
| `sec_html_safe` | Noul | Does the change mark user-influenced content as `html_safe` or use `raw`? |
| `sec_open_redirect` | Noul | Does the change redirect to a URL derived from params or headers without an allowlist? |
| `sec_unsafe_deserialization` | Noul | Does the change deserialize untrusted data with `YAML.load`, `Marshal.load`, or `JSON.load` with `create_additions`? |
| `sec_path_from_input` | Noul | Does the change build a file path, shell command, or system call from user input? |
| `sec_csrf_disabled` | Noul | Does the change skip CSRF verification or authentication with a `skip_before_action`? |
| `sec_secret_in_code` | Noul | Does the change include a credential, token, or key in source rather than credentials or environment? |
| `sec_pii_in_logs` | Noul | Does the change log, cache, or put in an error message a value that could be personal data or a credential? |
| `sec_timing_safe_compare` | Noul | Does the change compare a token, signature, or password with `==` instead of a constant-time comparison? |
| `sec_unbounded_input` | Noul | Does the change accept user input (file upload, array param, page size, text length) with no size or count limit? |
| `sec_homemade_primitive` | Noul | Does the change implement its own token generation, hashing, signing, or session handling instead of the Rails or library primitive? |

## Mike Perham — background jobs and concurrency

Source: Sidekiq best practices and wiki. Lens: jobs run twice, run late, run out of order, and run against a database that has moved on.

| ID | Type | Question |
| --- | --- | --- |
| `job_failure_impact` | Score | If a job in this change fails or runs twice, what happens? — 0 no jobs, or retries cleanly with no side effect · 1 duplicate work with no external effect · 2 duplicate external side effect (email, notification, API call) · 3 duplicate charge, double write, or corrupted data |
| `job_not_idempotent` | Noul | Does a job produce a different or harmful result if it runs twice with the same arguments? |
| `job_complex_args` | Noul | (ctx: BehavioralProfile queue adapter) Does a Sidekiq-native job take an ActiveRecord object, a Proc, or a nested structure as an argument instead of simple IDs and primitives? Active Job arguments may pass records via GlobalID. |
| `job_enqueued_inside_transaction` | Noul | (ctx: Rails version, queue adapter, enqueue\_after\_transaction\_commit setting) Does the change enqueue a job inside a transaction on a Rails version or adapter that does not defer the enqueue until commit, so the job may run before the write is visible? |
| `job_assumes_record_exists` | Noul | Does a job assume the record it was enqueued for still exists and is in the same state? |
| `job_no_retry_strategy` | Noul | Does a job with side effects (email, payment, external API) lack an explicit retry or dead-letter decision? |
| `job_read_modify_write` | Noul | Does the change read a value, compute from it, and write it back without a lock or atomic update? |
| `job_unbounded_fanout` | Noul | Does the change enqueue one job per record for a collection with no upper bound? |
| `job_shared_mutable_state` | Noul | Does the change mutate class-level or global state that multiple threads or job workers could touch? |
| `job_long_running_no_checkpoint` | Noul | Does a job process a large batch with no progress checkpoint, so a restart repeats all the work? |

## Observability — can you debug it at 3am?

Source: Rails error reporter and structured event guides, Semantic Logger and Lograge write-ups, Sidekiq docs. No persona on the council owned this; Charity Majors' framing is borrowed for the question. Runs on rescue blocks, log calls, raises, and job definitions in the diff.

| ID | Type | Question |
| --- | --- | --- |
| `obs_debuggability` | Score | If this change fails in production, how much would an engineer have to work with? — 0 error reported with context, ids, and the original cause · 1 error reported, context thin · 2 logged only, no report · 3 silent, swallowed, or a vague message |
| `obs_cause_lost` | Noul | Does a rescue raise a new exception in a way that drops the original as `cause`? |
| `obs_error_not_reported` | Noul | Does the change handle an error without reporting it through `Rails.error` or the app's error reporter? |
| `obs_log_without_context` | Noul | Does the change log a message with no identifying context (record id, user, request, job)? |
| `obs_new_integration_uninstrumented` | Noul | Does the change add an external call, job, or critical path with no instrumentation, event, or metric? |
| `obs_error_message_vague` | Noul | Does a raised error's message omit which record, operation, or input failed? |
| `obs_filter_parameters_missing` | Noul | Does the change add a param or attribute that is sensitive without adding it to `filter_parameters`? |
| `obs_exception_outside_hierarchy` | Noul | Does the change define an exception class that does not inherit from the app's base error? |
| `obs_retries_exhausted_unhandled` | Noul | Does a job with side effects lack a `sidekiq_retries_exhausted` or `discard_on` decision? |
| `obs_wrong_log_level` | Noul | Does the change log an expected condition at error level, or a failure at info or debug? |

## The codebase — does this look like it belongs here?

No persona. The reviewer is the repo itself. State must carry two or three sibling files from the same layer doing a comparable job (same directory, same superclass, or same concern), chosen deterministically. This is the cheapest context to pack and the one most likely to catch an agent drifting from house style.

| ID | Type | Question |
| --- | --- | --- |
| `repo_different_approach` | Noul | **(ctx: siblings)** Does the change solve its problem in a different way than the sibling files solve the same kind of problem? |
| `repo_naming_drift` | Noul | **(ctx: siblings)** Does the change name methods, variables, or classes differently than the naming pattern in the sibling files? |
| `repo_wrong_layer` | Noul | **(ctx: siblings)** Does the change put logic in a different layer than the codebase puts that kind of logic? |
| `repo_reinvents_local_helper` | Noul | **(ctx: grep for helpers, concerns, base classes)** Does the change introduce a helper, concern, or pattern when an equivalent already exists in the codebase? |
| `repo_ignores_base_class` | Noul | **(ctx: siblings)** Does the change bypass a base class, concern, or callback that the sibling files rely on? |
| `repo_inconsistent_error_handling` | Noul | **(ctx: siblings)** Does the change handle errors differently than the sibling files do? |
| `repo_inconsistent_return_shape` | Noul | **(ctx: siblings)** Does the change return a different shape (result object, boolean, record, raise) than the sibling files return for the same kind of operation? |
| `repo_fit` | Score | **(ctx: siblings)** How well does this match the surrounding code? — 0 indistinguishable · 1 same approach, small style differences · 2 recognizably different approach · 3 contradicts an established pattern |

## Rollout — can we ship and unship this?

No persona. Lens: the deploy and the migration are separate events, and the previous version of the code is still running for a while.

| ID | Type | Question |
| --- | --- | --- |
| `rollout_user_visibility` | Score | How much will a user notice this change? — 0 invisible · 1 cosmetic or wording · 2 changes a flow, form, or response shape · 3 removes or replaces something users rely on |
| `rollout_behavior_change_scope` | Score | **(ctx: git blame age of changed lines)** How much existing behavior does this change alter? — 0 none, purely additive · 1 edge cases of existing behavior · 2 the main path of recently added behavior · 3 the main path of long-standing behavior that users or other systems likely depend on |
| `rollout_code_needs_migration_first` | Noul | Does the code depend on a schema change in the same diff, so it breaks if deployed before the migration runs? |
| `rollout_migration_breaks_old_code` | Noul | Does a migration remove or rename something the currently deployed code still reads or writes? |
| `rollout_not_reversible` | Noul | Would reverting this deploy leave data in a state the previous code cannot handle? |
| `rollout_no_flag_for_risky_change` | Noul | Does the change alter user-facing behavior for everyone at once with no feature flag or gradual path? |
| `rollout_backfill_in_request` | Noul | Does the change rely on a backfill or data fix that has not been run? |
| `rollout_config_change_untracked` | Noul | Does the change require an environment variable, credential, or infrastructure change not present in the diff? |
| `rollout_public_api_no_deprecation` | Noul | Does the change remove or rename a public method, option, or route without a deprecation path? |
| `rollout_scheduled_task_untracked` | Noul | **(ctx: PR description)** Does the change add a cron or scheduled task with no deploy step recorded? |
| `rollout_destructive_migration_no_backup` | Noul | **(ctx: PR description)** Does a migration destroy or rewrite data with no backup step recorded for the deploy? |

## Data blast radius — what else does this touch?

No persona. Distinct from `metz_blast_radius`, which measures cost of change; this measures reach into data other code depends on. State must carry callers and references found by grep for every method, column, constant, and route the diff touches.

| ID | Type | Question |
| --- | --- | --- |
| `blast_data_reach` | Score | **(ctx: callers)** How far does this change's effect on stored data reach? — 0 only records the change itself creates · 1 existing records of one user or account · 2 records shared across many users or processes · 3 global, cross-tenant, or every row of a table |
| `blast_shared_data_write` | Noul | **(ctx: callers)** Does the change write to data that other code paths in the state also read or write? |
| `blast_dangling_reference` | Noul | **(ctx: grep)** Does the change rename or remove a method, column, constant, or route that something else still references? |
| `blast_callback_reach` | Noul | **(ctx: callers)** Does the change alter a callback, validation, scope, or default that fires on writes from other code paths? |
| `blast_race_condition` | Noul | Could two concurrent requests or jobs running this change produce a different result than running them one after the other? |
| `blast_shared_record` | Noul | Does the change mutate a record many users or processes share (account, settings, counter, cache row)? |
| `blast_orphans_records` | Noul | Does the change delete or nullify records that other records reference? |
| `blast_changes_serialized_shape` | Noul | Does the change alter the shape of data that is serialized, cached, or stored as JSON, so existing stored values no longer match? |

## Change hygiene — does the diff match the intent?

No persona. State must carry the PR description or commit message. Catches scope creep and silent behavior changes.

| ID | Type | Question |
| --- | --- | --- |
| `hygiene_unrelated_changes` | Noul | **(ctx: PR description)** Does the diff include changes unrelated to the stated intent? |
| `hygiene_undescribed_behavior_change` | Noul | **(ctx: PR description)** Does the diff change behavior that the description does not mention? |
| `hygiene_dead_code` | Noul | Does the change leave behind code, comments, or feature flags that nothing references? |
| `hygiene_debug_artifacts` | Noul | Does the change include `binding.pry`, `puts`, `console.log`, `.only`, `focus: true`, or commented-out code? |
| `hygiene_todo_without_owner` | Noul | Does the change add a TODO, FIXME, or HACK with no linked issue or owner? |
| `hygiene_silent_default_change` | Noul | Does the change alter a default value, timeout, limit, or configuration constant without calling it out? |
| `hygiene_comment_explains_what` | Noul | Does the change add a comment that restates what the code does rather than why? |
| `hygiene_commit_message_why` | Noul | **(ctx: commit messages)** Does the commit message say what changed without saying why, or omit the issue it fixes? |
| `hygiene_cosmetic_only` | Noul | Is the change purely cosmetic, adding nothing to stability, functionality, or testability? |
| `hygiene_changelog_missing` | Noul | **(ctx: whether the repo keeps a changelog)** Does a behavior change or new feature lack a changelog or release-note entry? |
| `hygiene_docs_stale` | Noul | Does the change alter a documented public method, option, or config without updating its documentation? |
| `hygiene_moves_logic_out_of_coverage` | Noul | Does the change move logic into a new code path that existing tests no longer exercise? |
| `dep_upgrade_no_reason` | Noul | **(ctx: Gemfile.lock diff, PR description)** Does a dependency upgrade lack a reason or a link to the dependency's changelog? |
| `hygiene_can_simplify` | Noul | **(ctx: siblings)** Could this code be made simpler while still meeting the standards shown in the sibling files? |
| `hygiene_can_optimize` | Noul | **(ctx: siblings)** Could this code be made faster or cheaper while still meeting the standards shown in the sibling files? |
| `disposition` | Choice | **(ctx: siblings)** What is the most useful next step for this change? — `approve` ready as written · `simplify` correct but could be simpler within codebase standards · `optimize` correct but leaves a clear performance improvement on the table · `rework` has a correctness, security, or data problem that polish will not fix |
| `primary_concern` | Choice | If one reviewer should look at this first, which domain is it? — `none` nothing stands out · `correctness` wrong result or unhandled path · `security` · `performance` · `data` migration, integrity, blast radius · `design` coupling, abstraction, fit with codebase · `rollout` deploy ordering, reversibility, user impact · `observability` cannot be debugged when it fails |
| `change_kind` | Choice | What kind of change is this? — `feature` new behavior · `fix` corrects existing behavior · `refactor` no behavior change intended · `migration` schema or data · `config` settings, dependencies, infrastructure · `test` tests only · `mixed` more than one of the above in one diff |

Three Choices live here. `change_kind` selects which reviewers' bars get weighted up when a human or agent reads the chart; `mixed` is the escape hatch a Choice needs so a feature-plus-migration diff is not forced into one bucket. `primary_concern` is an independent cross-check on the chart: if it says `security` and the security bar is flat, one of the two is miscalibrated. `disposition` is the one question that returns a recommendation rather than a fault probability; `rework` is its escape hatch so broken code is not filed under `simplify`. It is paired with `hygiene_can_simplify` and `hygiene_can_optimize` as independent Nouls; if calibration shows both Nouls firing together often, the Choice is hiding a real both-of-the-above and should be dropped in favor of the Nouls.

## Review notes — gaps found, attribution fixes, known blind spots

What changed from the chat draft, and what still isn't covered.

**Gaps filled**

- Security had no reviewer at all. Added 14 questions under Collins / Rails Security Guide.
- Background jobs and concurrency had no owner. Added Perham.
- Tests were in the earliest draft, then dropped. Restored under Metz (POODR ch. 9).
- Data integrity (constraints vs validations, irreversible migrations, data-in-schema-migration) was thin. Added to Uchitelle.
- Rollout safety and change hygiene are new sections with no persona; nobody on the council owns "will the deploy break."

**Attribution fixes**

- `avdi_interleaved_checks` was worded as "buries its main path under guard clauses." Backwards: *Confident Ruby* argues *for* early guards. Reworded to target checks scattered through the body.
- SQL string interpolation moved from tenderlove to security. It is a perf concern too (no prepared statement), but injection is the reason it matters.
- `metz_premature_abstraction` uses the rule of three, which is Fowler and Beck, not Metz. Her line is "duplication is far cheaper than the wrong abstraction." Kept under Metz because the lens is hers; the threshold is borrowed.
- The migration-safety questions are Andrew Kane's strong\_migrations rules more than Uchitelle's writing. Noted in the section source line.

**Known blind spots — not yet covered**

- Accessibility: one basics Noul in Views; no dedicated reviewer.
- API contracts: response shape changes, versioning, breaking clients. Partly in `metz_blast_radius` level 3 and `rollout_public_api_no_deprecation`; deserves its own section if the app has external API consumers.
- Ruby-level correctness beyond Avdi: mutable default args, `==` vs `eql?`, encoding, integer overflow in money math. Mostly cops.
- Multi-tenancy is only touched by `sec_unscoped_lookup`. If tenancy is a first-class concept in the app, it needs a reviewer.
- Views, Hotwire, and observability were listed here on the first pass; both now have sections, filled from the Gap research tab.

**Structural caveats**

- Every question is answered in isolation. A reviewer's mean will drift high if two questions describe the same fault from two angles. Calibration should look for pairs that always fire together and merge them.
- Noul has no confidence field. A 0.5 means "equal odds," not "medium severity." Chart the raw probability; don't threshold until the labeled set exists.
- The ctx-marked questions are only as good as the state packing. A `metz_depends_on_volatile` with no churn data in the state will return noise, and the noise will look like a real number.

## Type review — Noul, Score, or Choice

The rule applied: a Noul is a fault detector, a Score is an impact gauge, a Choice is a router. The first pass over-used Noul because "probability something is wrong" is easy to chart, but a mean of yes/no probabilities has no confidence value and treats a typo and a data-loss bug the same.

**Structural change: one headline Score per reviewer.** Every section now opens with a Score that rates impact on a described spectrum. That Score is the reviewer's bar on the chart. It is calibrated, carries `confidence`, and does not need normalization tricks over a pile of Nouls. The Nouls remain as the itemized findings that explain the bar. Reviewers that already had a Score (DHH, Metz, codebase) keep it; the rest gained one.

| Reviewer | Headline Score | What it gauges |
| --- | --- | --- |
| Berkopec | `perf_impact` | cost per request at scale |
| Uchitelle | `db_migration_risk` | lock, rewrite, data loss |
| Avdi | `avdi_return_contract` | how far a caller can trust the return |
| tenderlove | `vm_memory_impact` | garbage vs retained growth |
| Security | `sec_worst_case_impact` | who can reach whose data |
| Perham | `job_failure_impact` | what a retry or double-run does |
| Blast radius | `blast_data_reach` | how many rows or tenants |
| Tests | `test_coverage_of_change` | none through edge cases |
| Rollout | `rollout_user_visibility`, `rollout_behavior_change_scope` | what users notice, how much old behavior moves |

**Noul → Score conversions.** Four questions were binary in wording but spectrum in substance: `db_unsafe_migration`, `test_missing_for_change`, `rollout_user_interaction_change`, `rollout_alters_longstanding_behavior`. Each now has levels with a level 0 that means "not present," so the Score subsumes the old yes/no.

**Choice changes.** `change_kind` gained `mixed`; `disposition` gained `rework`; both were missing the escape option the docs call for. `primary_concern` is new: a router that answers "which domain first" in one shot, independent of the aggregated bars, so the two can be checked against each other.

**Kept as Noul on purpose.** `metz_reaches_through` (Demeter depth is countable but the finding is binary), `metz_argument_order` and `avdi_rescue_too_broad` (both cops, kept for cross-validation), and every security Noul (each one is a distinct fault; severity lives in the headline Score).

**Unused primitive features worth applying at calibration.**

- Noul `criteria`: an optional description of what yes and no mean. Five Nouls have a fuzzy yes and should get one: `metz_asks_instead_of_tells`, `avdi_unguarded_input`, `job_not_idempotent`, `blast_race_condition`, `dhh_pattern_indirection`.
- Structured Score levels (`what` + `examples`): when a Score keeps landing between two levels on inputs that seem clear, give each level two or three example situations drawn from the labeled set. The docs show this raising confidence from 0.54 to 0.90 on the same input.
- Choice `other`: every Choice now has one. Keep it when adding options.

**Not converted, and why.** A Choice for "which layer does this touch" was considered and rejected: file paths answer it deterministically. A Choice for "who on the team should review" is org-specific and belongs in the code that reads the chart, not in the bank.

## Changelog

| Date | Change |
| --- | --- |
| 2026-09-19 | Post-review corrections. Direction and kind conventions and explicit headline mapping added to Purpose. `ar_skips_validations` split by mechanism and `toggle` corrected. `ar_find_by_memoized` row repaired (pipe characters had broken the table cell). `job_complex_args` scoped to Sidekiq-native; `job_enqueued_inside_transaction` given a Rails-version premise. `metz_depends_on_volatile` matched to what Woods measures. Corrected count: 16 sections, 204 questions (185 Noul, 16 Score, 3 Choice). |
| 2026-09-19 | Gap research merged. Three new sections (Views and Hotwire, Batsov style-guide semantics, Observability), each with a headline Score; 40 rows added to existing sections; Tests source line now credits Searls and Dementyev; `primary_concern` gained `observability`. |
| 2026-09-19 | Gap research tab added: 81 candidate questions from thoughtbot, the Rails style guide, Rails AntiPatterns, Ruby Science, Searls, Evil Martians, and rails/rails PR standards. |
| 2026-09-19 | Type review. Headline Score added to every reviewer; four Nouls converted to Scores; `primary_concern` Choice added; `mixed` and `rework` escape options added. |
| 2026-09-19 | Added user-interaction and long-standing-behavior Nouls to Rollout; new Data blast radius section (7 Nouls); `disposition` Choice plus simplify/optimize Nouls in Change hygiene. |
| 2026-09-19 | Initial bank. 12 sections, 101 questions. Security, jobs, tests, rollout, hygiene added after gap review. |
