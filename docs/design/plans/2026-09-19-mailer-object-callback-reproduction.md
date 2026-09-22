# Confirmed: mailer object callbacks retain process-local identities

This is a focused bug report for the adjacent Woods development session.
No GitHub issue or PR comment has been created.

## Reproduction and scope

Verified with Ruby 4.0.6 and Rails 8.0.5.1 on PR #487 head
`a7e6fc6371200fb1a8def7a916063930b274e372`. The two affected files are byte-identical
on the subsequently observed main `287d1d29117b9890ce02a2f1a95cf978925b7d04`.

A supported Rails callback object still serializes with its object address:

```ruby
class MailerAuditCallback
  def before(_mailer)
    raise 'object callback ran'
  end
end

class ProbeMailer < ActionMailer::Base
  before_action MailerAuditCallback.new
  def sample; end
end
```

Run the standalone reproduction from the Woods checkout being tested, using its
existing Rails appraisal bundle:

```bash
BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile bundle exec ruby -Ilib \
  script/typesafe/probes/mailer_object_determinism.rb
```

Expected: equivalent boots emit equal callback metadata. Observed: exit 1 and
`stable: false`; each boot emits a different filter such as
`#<MailerAuditCallback:0x00007f6e1630e068>` versus
`#<MailerAuditCallback:0x00007f11c1cac6a8>`.
The probe also verifies that extraction does not run the callback and that normal
ActionMailer processing invokes it. This is not an unsupported registration shape.

## Mechanism and impact

`lib/woods/extractors/shared_utility_methods.rb`, `stable_filter`, only normalizes
`Proc` objects. It returns other callback objects unchanged. In
`lib/woods/extractors/mailer_extractor.rb`, `extract_callbacks` then calls
`callback_filter(cb).to_s`, preserving the object's default address-bearing string.

The observed impact is unstable serialized callback metadata across equivalent
processes. The annotated-source hash remains equal in this example, because the
hash covers source text; do not report source-hash drift or cache invalidation as
observed effects. No mail delivery failure or callback execution during extraction
was observed. This is a pre-existing uncovered case, not a regression introduced
by #487's Proc handling.

## Suggested next investigation

Add the object-callback case to the independent-boot regression and choose a stable
representation with an explicit contract for opaque instances, anonymous classes
and custom string representations. Preserve strings, symbols and legitimate
literal hexadecimal text. Avoid invoking the callback or inspecting arbitrary
instance state. Changing the shared helper may affect other extractors: verify
their public payload contracts and Rails-version behavior before adopting a fix.
No implementation change is included in this report.

## Evidence and attribution

Raw two-boot records, real-callback verification and current-main file digests:
`tmp/typesafe-pr-trial-2026-09-19/object-callback-probe/`.

In the accompanying Jev experiment, broad screening raised a remaining determinism
concern on the proposed mailer code and independently selected `stable_filter` as
the first source span to inspect. Jev did not name object callbacks or explain the
failure. Coordinator inspection and the executable probe established this specific
mechanism; do not credit it as autonomous model bug discovery.
