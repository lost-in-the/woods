#!/usr/bin/env python3
"""Portable bootstrap for the original four booted Rails defect/control pairs.

Requires the public Woods testbed source plus a cached Rails Docker image and
bundle volume. All database, Git, and generated-index writes stay under output.
No inference requests are made. See fixtureREADME.md for fresh-checkout steps.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import random
import shlex
import shutil
import subprocess
import time

import build_extra_pairs as shared

HERE = Path(__file__).resolve().parent
APP_RELATIVE = Path("apps/rails-8.0-large")

COMMON={
'app/models/review_item.rb':'''class ReviewItem < ApplicationRecord
  include NormalizesReviewName
end
''',
'app/models/concerns/normalizes_review_name.rb':'''module NormalizesReviewName
  extend ActiveSupport::Concern
  included do
    before_save :normalize_review_name
  end
  private
  def normalize_review_name
    self.normalized_name = name.to_s.strip.downcase
  end
end
''',
'app/services/review_rename.rb':'''class ReviewRename
  def self.call(item, name)
    raise NotImplementedError
  end
end
''',
'app/controllers/review_base_controller.rb':'''class ReviewBaseController < ActionController::Base
  before_action :require_reviewer
  private
  def require_reviewer
    head :forbidden unless request.headers['X-Review-Role'] == 'reviewer'
  end
end
''',
'app/controllers/review_reports_controller.rb':'''class ReviewReportsController < ReviewBaseController
  def show
    render plain: 'private report'
  end
  def preview
    render plain: 'public preview'
  end
end
''',
'app/models/review_delivery.rb':'''class ReviewDelivery < ApplicationRecord
  private
  def dispatch_review_delivery
    ReviewDeliveryJob.perform_later(id)
  end
end
''',
'app/jobs/review_delivery_job.rb':'''class ReviewDeliveryJob < ApplicationJob
  self.queue_adapter = :test
  self.enqueue_after_transaction_commit = false
  def perform(delivery_id)
    ReviewDelivery.find(delivery_id)
  end
end
''',
'app/models/review_registry_entry.rb':'''class ReviewRegistryEntry < ApplicationRecord
  validates :external_key, presence: true, uniqueness: true
end
''',
'db/migrate/20260921000001_create_review_pilot_tables.rb':'''class CreateReviewPilotTables < ActiveRecord::Migration[8.0]
  def change
    create_table :review_items do |t|
      t.string :name
      t.string :normalized_name
    end
    create_table :review_deliveries do |t|
      t.string :payload
    end
    create_table :review_registry_entries do |t|
      t.string :external_key, null: false
    end
  end
end
''',
'config/initializers/review_pilot.rb':'''Woods.configure do |config|
  config.console_mcp_enabled = false
  config.session_tracer_enabled = false
end
Rails.application.config.active_job.queue_adapter = :test
'''
}

def definitions():
    return [
('callback','Renaming an item must persist the submitted name and keep normalized_name equal to the stripped lowercase name used by lookups.','app/services/review_rename.rb',[
'''class ReviewRename
  def self.call(item, name)
    item.update_columns(name: name)
  end
end
''',
'''class ReviewRename
  def self.call(item, name)
    item.update!(name: name)
  end
end
'''],['app/models/review_item.rb','app/models/concerns/normalizes_review_name.rb'],[['ReviewRename','service'],['ReviewItem','model'],['NormalizesReviewName','concern']]),
('authorization','Preview is intentionally public. Showing the private report must continue to require the inherited reviewer-role check.','app/controllers/review_reports_controller.rb',[
COMMON['app/controllers/review_reports_controller.rb'].replace('  def show', '  skip_before_action :require_reviewer, only: :show\n  def show'),
COMMON['app/controllers/review_reports_controller.rb'].replace('  def show', '  skip_before_action :require_reviewer, only: :preview\n  def show')],['app/controllers/review_base_controller.rb'],[['ReviewReportsController','controller'],['ReviewBaseController','controller']]),
('transaction','Creating a delivery schedules one job after commit; rolling back its transaction must leave no queued job.','app/models/review_delivery.rb',[
COMMON['app/models/review_delivery.rb'].replace('  private', '  after_save :dispatch_review_delivery\n  private'),
COMMON['app/models/review_delivery.rb'].replace('  private', '  after_create_commit :dispatch_review_delivery\n  private')],['app/jobs/review_delivery_job.rb'],[['ReviewDelivery','model'],['ReviewDeliveryJob','job']]),
('schema','External registry keys must be unique at the database layer, including concurrent writes and bulk inserts that bypass model validation.','db/migrate/20260921000002_index_review_registry_keys.rb',[
'''class IndexReviewRegistryKeys < ActiveRecord::Migration[8.0]
  def change
    add_index :review_registry_entries, :external_key
  end
end
''',
'''class IndexReviewRegistryKeys < ActiveRecord::Migration[8.0]
  def change
    add_index :review_registry_entries, :external_key, unique: true
  end
end
'''],['app/models/review_registry_entry.rb'],[['ReviewRegistryEntry','model'],['IndexReviewRegistryKeys','migration']])]


def copied_source(testbed_root, base, bundle_lock):
    """Copy tracked application source, never live databases or local secrets."""
    source_app = testbed_root / APP_RELATIVE
    if not (source_app / "Gemfile").is_file():
        raise SystemExit(f"No Rails template at {source_app}")
    names = subprocess.check_output(
        ["git", "-C", str(testbed_root), "ls-files", "-z", "--", str(APP_RELATIVE)]
    ).decode().split("\0")
    files = {}
    for name in filter(None, names):
        source = testbed_root / name
        relative = source.relative_to(source_app)
        if source.is_symlink():
            raise SystemExit(f"Refusing source symlink: {relative}")
        target = base / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        files[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()
    lock = bundle_lock or source_app / "Gemfile.lock"
    if lock.is_file():
        shutil.copy2(lock, base / "Gemfile.lock")
    for directory in ["tmp", "log", "db"]:
        (base / directory).mkdir(exist_ok=True)
    return files


def prepare(args):
    output = shared.OUTPUT
    base = output / "base"
    if output.exists() and any(output.iterdir()):
        raise SystemExit("Refusing to overwrite an existing output directory")
    output.mkdir(parents=True, exist_ok=True)
    (output / "results").mkdir()
    files = copied_source(args.testbed_root, base, args.bundle_lock)
    for path, source in COMMON.items():
        shared.write(base / path, source)
    with (base / "config/routes.rb").open("a") as stream:
        stream.write("\nRails.application.routes.draw do\n  get '/review_reports/show', to: 'review_reports#show'\n  get '/review_reports/preview', to: 'review_reports#preview'\nend\n")
    steps = "bundle lock --local && bundle check && bundle exec rails db:prepare"
    command = shared.docker(base, steps, "woods-original-fixture-bootstrap")
    with (output / "prepare.log").open("w") as stream:
        subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=300)
    shared.git(base, "init", "-q")
    shared.git(base, "config", "user.name", "Woods Evaluation")
    shared.git(base, "config", "user.email", "evaluation@example.invalid")
    shared.git(base, "add", ".")
    shared.git(base, "commit", "-qm", "Application baseline for isolated review trial")
    base_sha = shared.git(base, "rev-parse", "HEAD")
    cases = []
    target_ids = {
        "callback": ["ar_skips_validations"],
        "authorization": ["sec_missing_authorization", "sec_csrf_disabled"],
        "transaction": ["job_enqueued_inside_transaction"],
        "schema": ["db_validation_without_constraint"],
    }
    for pair_number, (family, brief, path, variants, support, identities) in enumerate(definitions(), 1):
        for variant, source in enumerate(variants):
            cid = hashlib.sha256((family + str(variant) + "20260921").encode()).hexdigest()[:8]
            app = output / "apps" / cid
            shutil.copytree(base, app, ignore=shutil.ignore_patterns("tmp", "log", "*.sqlite3-*"))
            for directory in ["tmp", "log"]:
                (app / directory).mkdir()
                if (base / directory / ".keep").is_file():
                    shutil.copy2(base / directory / ".keep", app / directory / ".keep")
            shared.write(app / path, source)
            shared.git(app, "add", path)
            shared.git(app, "commit", "-qm", "Candidate application change")
            head = shared.git(app, "rev-parse", "HEAD")
            cases.append({
                "id": cid, "family": family, "pair_id": f"original-{pair_number:02}",
                "split": "development", "defect": variant == 0, "brief": brief,
                "path": path, "support": support, "identities": identities,
                "target_question_ids": target_ids[family], "base": base_sha, "head": head,
                "app_path": str(app), "changed_paths": [path],
                "diff": shared.git(app, "diff", "--no-ext-diff", "--unified=8", base_sha, head, "--", path),
            })
    random.Random(20260921).shuffle(cases)
    shared.save_json(output / "cases.json", cases)
    shutil.copy2(HERE / "original_collector.rb", output / "original_collector.rb")
    shared.save_json(output / "fixture-freeze.json", {
        "frozen_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "woods_head": shared.git(shared.REPO, "rev-parse", "HEAD"),
        "testbed_head": shared.git(args.testbed_root, "rev-parse", "HEAD"),
        "base": base_sha, "inference_calls": 0, "holdout_cases": [],
        "cases_sha256": hashlib.sha256((output / "cases.json").read_bytes()).hexdigest(),
        "builder_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "collector_sha256": hashlib.sha256((HERE / "original_collector.rb").read_bytes()).hexdigest(),
    })
    shared.save_json(output / "preparation-receipt.json", {
        "source_template": str(args.testbed_root / APP_RELATIVE),
        "source_files_sha256": files, "bootstrap_command": command,
        "docker_image": shared.IMAGE, "bundle_volume": shared.VOLUME,
        "bundle_lock_sha256": hashlib.sha256((base / "Gemfile.lock").read_bytes()).hexdigest(),
        "database": "New private SQLite database created by db:prepare from copied source; no original database read or written",
        "case_count": len(cases), "inference_calls": 0,
    })
    print(f"Prepared {len(cases)} original cases at {output}", flush=True)


def run_case(case):
    output = shared.OUTPUT
    cid = case["id"]
    app = Path(case["app_path"])
    if shared.git(app, "status", "--porcelain"):
        raise RuntimeError(f"Refusing modified candidate {cid}")
    for sidecar in (app / "db").glob("test.sqlite3-*"):
        sidecar.unlink()
    shutil.copy2(output / "base/db/test.sqlite3", app / "db/test.sqlite3")
    if (app / "tmp/woods").exists():
        shutil.rmtree(app / "tmp/woods")
    start = time.monotonic()
    migration = shared.docker(app, "bundle exec rails db:migrate", f"woods-original-migrate-{cid}")
    log = output / "results" / f"{cid}.log"
    with log.open("w") as stream:
        subprocess.run(migration, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=240)
    # Preserve the proposed change SHA separately from schema materialization.
    # This is the same identity distinction supported by the original captures.
    shared.git(app, "add", "db/schema.rb")
    if shared.git(app, "diff", "--cached", "--name-only"):
        shared.git(app, "commit", "-qm", "Record migrated schema")
    case["materialized_head"] = shared.git(app, "rev-parse", "HEAD")
    # Each collector reads its immutable per-case metadata, avoiding concurrent
    # writes to the common manifest during schema materialization.
    shared.save_json(output / "results" / f"{cid}-case.json", case)
    steps = [
        "bundle exec ruby -I/woods-gem/lib /woods-gem/exe/woods-extract full",
        "bundle exec rails runner /evaluation/original_collector.rb",
    ]
    command = shared.docker(app, " && ".join(steps), f"woods-original-extract-{cid}")
    with log.open("a") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
    receipt = {"id": cid, "exit_code": result.returncode, "seconds": time.monotonic() - start,
               "migration_command": migration, "command": command, "steps": steps}
    shared.save_json(output / "results" / f"{cid}-run.json", receipt)
    print(json.dumps({k: receipt[k] for k in ["id", "exit_code", "seconds"]}), flush=True)
    return case, receipt


def run(args):
    output = shared.OUTPUT
    cases = json.loads((output / "cases.json").read_text())
    freeze = json.loads((output / "fixture-freeze.json").read_text())
    if shared.git(shared.REPO, "rev-parse", "HEAD") != freeze["woods_head"]:
        raise SystemExit("Woods HEAD changed since fixture preparation")
    selected = [case for case in cases if not args.only or case["id"] in args.only]
    if args.only and set(args.only) - {case["id"] for case in cases}:
        raise SystemExit("--only includes an unknown case ID")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run_case, selected))
    by_id = {case["id"]: case for case, _ in results}
    shared.save_json(output / "cases.json", [by_id.get(case["id"], case) for case in cases])
    shared.save_json(output / "app-runs.json", [receipt for _, receipt in results])
    if any(receipt["exit_code"] for _, receipt in results):
        raise SystemExit("One or more cases failed; inspect results logs")
    for case, _ in results:
        cid = case["id"]
        evidence = json.loads((output / "results" / f"{cid}-evidence.json").read_text())
        oracle = json.loads((output / "results" / f"{cid}-oracle.json").read_text())
        assert evidence["freshness"]["state"] == "current" and not evidence["working_tree"]
        assert evidence["checked_out_sha"] == case["materialized_head"]
        assert oracle["oracle_matches_intended_case"]
    shared.save_json(output / "validation.json", {
        "validated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "cases_verified": len(results), "current_deep_indexes": len(results),
        "matching_oracle_outcomes": len(results), "inference_calls": 0,
        "materialized_cases_sha256": hashlib.sha256((output / "cases.json").read_bytes()).hexdigest(),
    })
    print(f"Verified {len(results)} fresh original cases", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--testbed-root", type=Path, required=True)
    parser.add_argument("--woods-root", type=Path, default=shared.REPO)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle-lock", type=Path, help="Optional known lockfile; otherwise use template lockfile or cached local resolution")
    parser.add_argument("--image", default=shared.IMAGE)
    parser.add_argument("--bundle-volume", default=shared.VOLUME)
    parser.add_argument("--docker-command", default="docker")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    args.testbed_root = args.testbed_root.resolve()
    args.bundle_lock = args.bundle_lock.resolve() if args.bundle_lock else None
    shared.REPO, shared.OUTPUT = args.woods_root.resolve(), args.output.resolve()
    shared.IMAGE, shared.VOLUME = args.image, args.bundle_volume
    shared.DOCKER_COMMAND = shlex.split(args.docker_command)
    if not shared.DOCKER_COMMAND:
        parser.error("--docker-command cannot be empty")
    if not (shared.REPO / "exe/woods-extract").is_file():
        parser.error("--woods-root must name a Woods source checkout")
    if args.bundle_lock and not args.bundle_lock.is_file():
        parser.error("--bundle-lock must name an existing lockfile")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if shared.OUTPUT == args.testbed_root or shared.OUTPUT.is_relative_to(args.testbed_root):
        parser.error("--output must be outside the source testbed checkout")
    if not args.prepare and not args.run:
        args.prepare = args.run = True
    if args.prepare:
        prepare(args)
    if args.run:
        run(args)


if __name__ == "__main__":
    main()
