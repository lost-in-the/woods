# Release V2 Verification Record

## Branch Baseline

- Branch: `audit/v2-final-release`
- Base SHA: `8fea1922886ac34991820ddf6a97dae94fe06fa3`
- Base relationship command: `git merge-base HEAD 8fea1922886ac34991820ddf6a97dae94fe06fa3`
- Expected result: `8fea1922886ac34991820ddf6a97dae94fe06fa3`

## Clean Baseline Evidence

- Ruby: `ruby 4.0.1`
- Dependency bundle: `BUNDLE_PATH=/Users/egg/lost-in-the/woods/vendor/bundle`
- PATH: `PATH=/Users/egg/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`
- Command: `PATH=/Users/egg/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=/Users/egg/lost-in-the/woods/vendor/bundle bundle exec rake spec`
- Result: `6,304 examples, 0 failures, 4 pending, random seed 20215, 1m18.87s`
- Coverage command: `PATH=/Users/egg/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=/Users/egg/lost-in-the/woods/vendor/bundle COVERAGE=true bundle exec rake spec`
- Coverage result: `91.17% line coverage`; opt-in integration suites were excluded from that baseline.
- Main CI: [run 32302116061](https://github.com/lost-in-the/woods/actions/runs/32302116061), `21/21` jobs green.

## Inventory Contract

- Write command: `PATH=/Users/egg/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=/Users/egg/lost-in-the/woods/vendor/bundle bundle exec rake release_v2:write_surface_inventory`
- Verification command: `PATH=/Users/egg/.local/share/mise/installs/ruby/4.0.1/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin BUNDLE_PATH=/Users/egg/lost-in-the/woods/vendor/bundle bundle exec rake release_v2:verify_surface_inventory`
- CI location: the `lint` job runs the verification command before RuboCop.
- Contract source: `.Codex/release-v2/surface-inventory.json` is generated from code and must be regenerated in the same serial ledger update that changes a public surface.

## Ledger Discipline

`findings.json` updates are serial: update one finding, run its reproducer and the inventory verification command, then record the next finding update.
