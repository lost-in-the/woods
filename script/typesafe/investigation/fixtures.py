#!/usr/bin/env python3
"""Build four fresh, non-security Rails correctness pairs without provider calls.

Requires the disposable base from rails_bank/build_original_pairs.py and its
cached Rails image/bundle. Each candidate receives a private database and git
history. Cases/oracles are coordinator metadata: never serialize them wholesale
to a model. Only changed source and neutral card menus belong in initial state.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import time


REPO = Path(__file__).resolve().parents[3]
OUTPUT = None
TEMPLATE = None
RUNTIME = None
IMAGE = "woods-testbed-rails-8.0-large:latest"
VOLUME = "woods-testbed-bundle-rails-8-large"
DOCKER = ["docker"]
REVISION = "9f55ee840e22b160a148c48da3dcef1210d07ed7"
SEED = "rails-investigation-20260921-v1"


def write(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)


def save_json(path, value):
    write(path, json.dumps(value, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ruby(source):
    return "# frozen_string_literal: true\n\n" + source


def git(app, *args):
    return subprocess.check_output(["git", "-C", str(app), *args], text=True).strip()


def spec(klass, description, body):
    return ruby(f"require 'rails_helper'\n\nRSpec.describe {klass} do\n  it '{description}' do\n{body}\n  end\nend\n")


COMMON = {
    "app/models/investigation_digest.rb": ruby("""class InvestigationDigest < ApplicationRecord
  validates :heading, presence: true
  validates :window_days, numericality: { only_integer: true, greater_than: 0 }
end
"""),
    "app/models/investigation_pool.rb": ruby("""class InvestigationPool < ApplicationRecord
  has_many :investigation_reservations, dependent: :destroy
  validates :available, numericality: { only_integer: true }
end
"""),
    "app/models/investigation_reservation.rb": ruby("""class InvestigationReservation < ApplicationRecord
  belongs_to :investigation_pool
  validates :seats, numericality: { only_integer: true, greater_than: 0 }
end
"""),
    "app/models/investigation_attempt.rb": ruby("""class InvestigationAttempt < ApplicationRecord
  validates :outcome, inclusion: { in: %w[reserved unavailable] }
end
"""),
    "app/models/investigation_event.rb": ruby("""class InvestigationEvent < ApplicationRecord
  validates :label, presence: true
end
"""),
    "app/services/investigation_invoice_request.rb": ruby("""class InvestigationInvoiceRequest
  def self.call(json)
    lines = JSON.parse(json).fetch('lines')
    { total: InvestigationInvoiceTotal.call(lines).to_s('F'), currency: 'USD' }
  end
end
"""),
    "app/services/investigation_currency_label.rb": ruby("""class InvestigationCurrencyLabel
  def self.call(currency)
    { 'USD' => 'US dollars', 'CAD' => 'Canadian dollars' }.fetch(currency)
  end
end
"""),
    "app/services/investigation_invoice_reference.rb": ruby("""class InvestigationInvoiceReference
  def self.call(number)
    format('INV-%06d', Integer(number))
  end
end
"""),
    "app/services/investigation_digest_filename.rb": ruby("""class InvestigationDigestFilename
  def self.call(digest)
    "digest-#{digest.id}.json"
  end
end
"""),
    "app/services/investigation_digest_serialization.rb": ruby("""class InvestigationDigestSerialization
  def self.call(digest)
    JSON.generate(heading: digest.heading, window_days: digest.window_days)
  end
end
"""),
    "app/services/investigation_reservation_batch.rb": ruby("""class InvestigationReservationBatch
  def self.call(pool, seats)
    InvestigationPool.transaction do
      attempt = InvestigationAttempt.create!(outcome: 'unavailable')
      outcome = InvestigationReserveSeats.call(pool, seats)
      attempt.update!(outcome: outcome.to_s)
      outcome
    end
  end
end
"""),
    "app/services/investigation_pool_summary.rb": ruby("""class InvestigationPoolSummary
  def self.call(pool)
    { available: pool.available, reservations: pool.investigation_reservations.count }
  end
end
"""),
    "app/services/investigation_activity_export.rb": ruby("""class InvestigationActivityExport
  def self.call
    InvestigationTodayActivity.call.map { |event| { label: event.label, created_at: event.created_at.iso8601 } }
  end
end
"""),
    "app/services/investigation_activity_label.rb": ruby("""class InvestigationActivityLabel
  def self.call(event)
    "Event #{event.id}: #{event.label}"
  end
end
"""),
    "config/initializers/investigation_calendar.rb": ruby("Rails.application.config.time_zone = 'UTC'\nTime.zone = 'UTC'\n"),
    "db/migrate/20260921000004_create_investigation_tables.rb": ruby("""class CreateInvestigationTables < ActiveRecord::Migration[8.0]
  def change
    create_table :investigation_digests do |t|
      t.string :heading, null: false
      t.integer :window_days, null: false
    end
    create_table :investigation_pools do |t|
      t.integer :available, null: false
    end
    create_table :investigation_reservations do |t|
      t.references :investigation_pool, null: false, foreign_key: true
      t.integer :seats, null: false
    end
    create_table :investigation_attempts do |t|
      t.string :outcome, null: false
    end
    create_table :investigation_events do |t|
      t.string :label, null: false
      t.timestamps
    end
  end
end
"""),
}


def definitions():
    invoice_path = "app/services/investigation_invoice_total.rb"
    invoice_spec = "spec/services/investigation_invoice_total_spec.rb"
    digest_path = "app/services/investigation_digest_options.rb"
    digest_spec = "spec/services/investigation_digest_options_spec.rb"
    reserve_path = "app/services/investigation_reserve_seats.rb"
    reserve_spec = "spec/services/investigation_reserve_seats_spec.rb"
    calendar_path = "app/services/investigation_today_activity.rb"
    calendar_spec = "spec/services/investigation_today_activity_spec.rb"
    return [
        {
            "family": "invoice_rounding",
            "brief": "Reuse the line-amount calculator for nonempty invoice totals. Unit prices are decimal strings and quantities are positive integers. Sum exact extended amounts and round the invoice total to two decimal places once, with decimal half-up rounding; preserve credit amounts as well as charges.",
            "path": invoice_path,
            "before": ruby("""class InvestigationInvoiceTotal
  def self.call(lines)
    lines.sum { |line| BigDecimal(line.fetch('unit_price')) * line.fetch('quantity') }.round(2)
  end
end
"""),
            "after": [ruby("""class InvestigationInvoiceTotal
  def self.call(lines)
    InvestigationLineAmounts.call(lines).sum.round(2)
  end
end
""")] * 2,
            "background": [
                {"app/services/investigation_line_amounts.rb": ruby("""class InvestigationLineAmounts
  def self.call(lines)
    lines.map do |line|
      (BigDecimal(line.fetch('unit_price')) * line.fetch('quantity')).round(2)
    end
  end
end
""")},
                {"app/services/investigation_line_amounts.rb": ruby("""class InvestigationLineAmounts
  def self.call(lines)
    lines.map do |line|
      BigDecimal(line.fetch('unit_price')) * line.fetch('quantity')
    end
  end
end
""")},
            ],
            "cards": ["app/services/investigation_line_amounts.rb", "app/services/investigation_invoice_request.rb", "app/services/investigation_currency_label.rb", "app/services/investigation_invoice_reference.rb", invoice_spec],
            "necessary": ["app/services/investigation_line_amounts.rb"],
            "identities": [["InvestigationInvoiceTotal", "service"], ["InvestigationLineAmounts", "service"]],
            "test_path": invoice_spec,
            "test": spec("InvestigationInvoiceTotal", "totals decimal prices and quantities", """    lines = [{ 'unit_price' => '19.95', 'quantity' => 2 }, { 'unit_price' => '5.10', 'quantity' => 1 }]
    expect(described_class.call(lines)).to eq(BigDecimal('45.00'))"""),
        },
        {
            "family": "json_key_shape",
            "brief": "Simplify digest option handling while preserving the public JSON request's heading and window_days. The request accepts only these fixed presentation fields: nonempty text and a positive integer. Missing fields default to Daily activity and seven days; supplied valid fields must be persisted unchanged.",
            "path": digest_path,
            "before": ruby("""class InvestigationDigestOptions
  def self.call(options)
    values = options.stringify_keys
    { heading: values.fetch('heading', 'Daily activity'), window_days: values.fetch('window_days', 7) }
  end
end
"""),
            "after": [ruby("""class InvestigationDigestOptions
  def self.call(options)
    { heading: options.fetch(:heading, 'Daily activity'), window_days: options.fetch(:window_days, 7) }
  end
end
""")] * 2,
            "background": [
                {"app/services/investigation_digest_request.rb": ruby("""class InvestigationDigestRequest
  def self.call(json)
    options = JSON.parse(json).slice('heading', 'window_days')
    InvestigationDigest.create!(InvestigationDigestOptions.call(options))
  end
end
""")},
                {"app/services/investigation_digest_request.rb": ruby("""class InvestigationDigestRequest
  def self.call(json)
    options = JSON.parse(json, symbolize_names: true).slice(:heading, :window_days)
    InvestigationDigest.create!(InvestigationDigestOptions.call(options))
  end
end
""")},
            ],
            "cards": ["app/services/investigation_digest_request.rb", "app/models/investigation_digest.rb", "app/services/investigation_digest_filename.rb", "app/services/investigation_digest_serialization.rb", digest_spec],
            "necessary": ["app/services/investigation_digest_request.rb"],
            "identities": [["InvestigationDigestOptions", "service"], ["InvestigationDigestRequest", "service"], ["InvestigationDigest", "model"]],
            "test_path": digest_spec,
            "test": spec("InvestigationDigestOptions", "preserves supplied options and provides defaults", """    expect(described_class.call(heading: 'Weekly summary', window_days: 30)).to eq(heading: 'Weekly summary', window_days: 30)
    expect(described_class.call({})).to eq(heading: 'Daily activity', window_days: 7)"""),
        },
        {
            "family": "nested_reservation",
            "brief": "Persist seat reservations and return reserved or unavailable. A rejected request must leave the pool's available seats unchanged, including when the caller records an attempt in its own transaction. Successful requests deduct exactly the requested seats and create one reservation. Calls in this fixture are sequential.",
            "path": reserve_path,
            "before": ruby("""class InvestigationReserveSeats
  def self.call(pool, seats)
    pool.available >= seats ? :reserved : :unavailable
  end
end
"""),
            "after": [ruby("""class InvestigationReserveSeats
  def self.call(pool, seats)
    result = :unavailable
    InvestigationPool.transaction do
      pool.update!(available: pool.available - seats)
      raise ActiveRecord::Rollback if pool.available.negative?

      InvestigationReservation.create!(investigation_pool: pool, seats: seats)
      result = :reserved
    end
    result
  end
end
"""), ruby("""class InvestigationReserveSeats
  def self.call(pool, seats)
    result = :unavailable
    InvestigationPool.transaction(requires_new: true) do
      pool.update!(available: pool.available - seats)
      raise ActiveRecord::Rollback if pool.available.negative?

      InvestigationReservation.create!(investigation_pool: pool, seats: seats)
      result = :reserved
    end
    result
  end
end
""")],
            "background": [{}, {}],
            "cards": ["app/services/investigation_reservation_batch.rb", "app/models/investigation_pool.rb", "app/models/investigation_reservation.rb", "app/services/investigation_pool_summary.rb", reserve_spec],
            "necessary": ["app/services/investigation_reservation_batch.rb", "app/models/investigation_pool.rb"],
            "identities": [["InvestigationReserveSeats", "service"], ["InvestigationReservationBatch", "service"], ["InvestigationPool", "model"], ["InvestigationReservation", "model"]],
            "test_path": reserve_spec,
            "test": spec("InvestigationReserveSeats", "persists a successful reservation", """    pool = InvestigationPool.create!(available: 10)
    expect(described_class.call(pool, 3)).to eq(:reserved)
    expect(pool.reload.available).to eq(7)
    expect(pool.investigation_reservations.pluck(:seats)).to eq([3])"""),
        },
        {
            "family": "local_calendar_day",
            "brief": "Limit the activity export to events created during the application's configured current calendar day, in creation order. The operating-system clock is UTC; application calendar configuration is a separate premise. Include only events within that local day's boundaries, rather than a rolling 24-hour window.",
            "path": calendar_path,
            "before": ruby("""class InvestigationTodayActivity
  def self.call
    InvestigationEvent.order(:created_at).to_a
  end
end
"""),
            "after": [ruby("""class InvestigationTodayActivity
  def self.call
    InvestigationEvent.where(created_at: Date.today.all_day).order(:created_at).to_a
  end
end
""")] * 2,
            "background": [
                {"config/initializers/investigation_calendar.rb": ruby("Rails.application.config.time_zone = 'America/New_York'\nTime.zone = 'America/New_York'\n")},
                {"config/initializers/investigation_calendar.rb": COMMON["config/initializers/investigation_calendar.rb"]},
            ],
            "cards": ["config/initializers/investigation_calendar.rb", "app/models/investigation_event.rb", "app/services/investigation_activity_export.rb", "app/services/investigation_activity_label.rb", calendar_spec],
            "necessary": ["config/initializers/investigation_calendar.rb"],
            "identities": [["InvestigationTodayActivity", "service"], ["InvestigationActivityExport", "service"], ["InvestigationEvent", "model"]],
            "test_path": calendar_spec,
            "test": spec("InvestigationTodayActivity", "returns current activity in creation order", """    travel_to Time.utc(2026, 9, 21, 16, 0) do
      earlier = InvestigationEvent.create!(label: 'Earlier', created_at: Time.current - 1.hour)
      later = InvestigationEvent.create!(label: 'Later', created_at: Time.current)
      expect(described_class.call.map(&:id)).to eq([earlier.id, later.id])
    end"""),
        },
    ]


def docker(app, script, name):
    return [
        *DOCKER, "run", "--rm", "--pull=never", "--name", name,
        "--user", f"{os.getuid()}:{os.getgid()}", "--entrypoint", "bash",
        "-e", "BUNDLE_APP_CONFIG=/app/.bundle", "-e", "RAILS_ENV=test", "-e", "TZ=UTC",
        "-e", "SECRET_KEY_BASE=woods-disposable-investigation",
        "-e", f"INVESTIGATION_CASE={app.name}",
        "-v", f"{VOLUME}:/bundle:ro", "-v", f"{app}:/app",
        "-v", f"{RUNTIME}:/woods-gem:ro", "-v", f"{OUTPUT}:/evaluation",
        IMAGE, "-lc", script,
    ]


def copy_app(source, destination, keep_git=False):
    omitted = ["tmp", "log", "*.sqlite3", "*.sqlite3-*", ".bundle"]
    if not keep_git:
        omitted.append(".git")
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(*omitted))
    shutil.copy2(source / "db/test.sqlite3", destination / "db/test.sqlite3")
    for name in ["tmp", "log"]:
        (destination / name).mkdir(exist_ok=True)
        if (source / name / ".keep").exists():
            shutil.copy2(source / name / ".keep", destination / name / ".keep")


def initialize_git(app, message):
    git(app, "init", "-q")
    git(app, "config", "user.name", "Woods Evaluation")
    git(app, "config", "user.email", "evaluation@example.invalid")
    git(app, "add", ".")
    git(app, "commit", "-qm", message)


def card_id(path):
    return hashlib.sha256(f"{SEED}:card:{path}".encode()).hexdigest()[:10]


def prepare():
    if TEMPLATE is None or not (TEMPLATE / "db/test.sqlite3").is_file():
        raise SystemExit("--template must be an intact disposable Rails fixture base")
    if (OUTPUT / "base").exists():
        raise SystemExit("Refusing to overwrite prepared fixtures; use --run to resume")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "results").mkdir(exist_ok=True)
    # A tracked-source archive pins Woods even if the user's branch later moves.
    RUNTIME.mkdir()
    with tempfile.TemporaryFile() as archive:
        subprocess.run(["git", "-C", str(REPO), "archive", REVISION], stdout=archive, check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as tar:
            options = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
            tar.extractall(RUNTIME, **options)
    runtime_hashes = {str(path.relative_to(RUNTIME)): digest(path) for path in sorted(RUNTIME.rglob("*")) if path.is_file()}
    save_json(OUTPUT / "woods-runtime-files.json", runtime_hashes)
    base = OUTPUT / "base"
    copy_app(TEMPLATE, base)
    for path, source in COMMON.items():
        write(base / path, source)
    pairs = definitions()
    for pair in pairs:
        write(base / pair["path"], pair["before"])
        write(base / pair["test_path"], pair["test"])
        for path, source in pair["background"][1].items():
            write(base / path, source)
    migration = docker(base, "bundle exec rails db:migrate", "woods-investigation-prepare")
    with (OUTPUT / "prepare.log").open("w") as stream:
        subprocess.run(migration, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=240)
    cases = []
    for position, pair in enumerate(pairs):
        for variant in range(2):
            cid = hashlib.sha256(f"{SEED}:candidate:{position}:{variant}".encode()).hexdigest()[:10]
            app = OUTPUT / "apps" / cid
            copy_app(base, app)
            for path, source in pair["background"][variant].items():
                write(app / path, source)
            initialize_git(app, "Application baseline for source investigation")
            before = git(app, "rev-parse", "HEAD")
            write(app / pair["path"], pair["after"][variant])
            git(app, "add", pair["path"])
            git(app, "commit", "-qm", "Candidate application change")
            after = git(app, "rev-parse", "HEAD")
            cards = []
            for path in sorted(pair["cards"], key=card_id):
                source = (app / path).read_text()
                cards.append({"id": card_id(path), "path": path, "source": source,
                              "sha256": digest(app / path), "line_start": 1,
                              "line_end": len(source.splitlines()),
                              "kind": "test" if path.startswith("spec/") else "config" if path.startswith("config/") else "source"})
            cases.append({
                "id": cid, "pair_id": f"investigation-{position + 1:02}",
                "family": pair["family"], "defect": variant == 0,
                "brief": pair["brief"], "path": pair["path"], "changed_paths": [pair["path"]],
                "base": before, "head": after, "app_path": str(app),
                "test_path": pair["test_path"], "identities": pair["identities"],
                "support": [card["path"] for card in cards], "cards": cards,
                "necessary_card_ids": [card_id(path) for path in pair["necessary"]],
                "diff": git(app, "diff", "--no-ext-diff", "--unified=8", before, after, "--", pair["path"]),
                "background_premise_paths": sorted(pair["background"][variant]),
            })
    random.Random(SEED).shuffle(cases)
    save_json(OUTPUT / "cases.json", cases)
    for name in ["collect.rb", "oracle.rb"]:
        shutil.copy2(Path(__file__).with_name(name), OUTPUT / name)
    image_id = subprocess.check_output([*DOCKER, "image", "inspect", "--format", "{{.Id}}", IMAGE], text=True).strip()
    save_json(OUTPUT / "fixture-freeze.json", {
        "frozen_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "woods_head": REVISION, "runtime_files_sha256": digest(OUTPUT / "woods-runtime-files.json"),
        "cases_sha256": digest(OUTPUT / "cases.json"), "builder_sha256": digest(Path(__file__)),
        "collector_sha256": digest(OUTPUT / "collect.rb"), "oracle_sha256": digest(OUTPUT / "oracle.rb"),
        "candidate_ids": [case["id"] for case in cases], "inference_calls": 0,
        "scope": "Four previously unexposed non-security correctness pairs; all fixed before provider inference",
        "privacy": "Case labels, family, necessary cards, runtime timezone and all oracle results are coordinator-only",
    })
    save_json(OUTPUT / "preparation-receipt.json", {
        "source_template": str(TEMPLATE), "source_database_sha256": digest(TEMPLATE / "db/test.sqlite3"),
        "base_database_sha256": digest(base / "db/test.sqlite3"),
        "woods_source": str(REPO), "woods_revision": REVISION, "woods_runtime": str(RUNTIME),
        "docker_image": IMAGE, "docker_image_id": image_id, "bundle_volume": VOLUME,
        "migration_command": migration, "case_count": len(cases),
        "initial_source": "Only changed_paths; support bodies require card inspection",
        "runtime_policy": "Captured timezone stays outside initial model premises; shared version/database/adapter only",
        "background_policy": "Three pairs have identical proposed diff/source but distinct pre-existing helper/caller/config premises. Reservation shares all background source and differs in savepoint use.",
    })
    print(f"Prepared {len(cases)} frozen candidates in {OUTPUT}", flush=True)


def run_case(case):
    app = Path(case["app_path"])
    cid = case["id"]
    if git(app, "status", "--porcelain") or git(app, "rev-parse", "HEAD") != case["head"]:
        raise RuntimeError(f"Candidate {cid} is modified")
    for sidecar in (app / "db").glob("test.sqlite3-*"):
        sidecar.unlink()
    shutil.copy2(OUTPUT / "base/db/test.sqlite3", app / "db/test.sqlite3")
    if (app / "tmp/woods").exists():
        shutil.rmtree(app / "tmp/woods")
    steps = [
        f"bundle exec rspec {case['test_path']} --format documentation",
        "bundle exec ruby -I/woods-gem/lib /woods-gem/exe/woods-extract full",
        "bundle exec rails runner /evaluation/collect.rb",
        "bundle exec rails runner /evaluation/oracle.rb",
    ]
    command = docker(app, " && ".join(steps), f"woods-investigation-{cid}")
    start = time.monotonic()
    with (OUTPUT / "results" / f"{cid}.log").open("w") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
    receipt = {"id": cid, "exit_code": result.returncode, "seconds": time.monotonic() - start,
               "command": command, "steps": steps, "woods_revision": REVISION}
    save_json(OUTPUT / "results" / f"{cid}-run.json", receipt)
    print(json.dumps({key: receipt[key] for key in ["id", "exit_code", "seconds"]}), flush=True)
    return receipt


def run(jobs, only):
    freeze = json.loads((OUTPUT / "fixture-freeze.json").read_text())
    if REVISION != freeze["woods_head"] or digest(Path(__file__)) != freeze["builder_sha256"]:
        raise SystemExit("Builder or requested Woods revision differs from fixture freeze")
    if digest(OUTPUT / "cases.json") != freeze["cases_sha256"]:
        raise SystemExit("Frozen case manifest changed")
    for name, key in [("collect.rb", "collector_sha256"), ("oracle.rb", "oracle_sha256"), ("woods-runtime-files.json", "runtime_files_sha256")]:
        if digest(OUTPUT / name) != freeze[key]:
            raise SystemExit(f"Frozen prerequisite changed: {name}")
    for path, sha in json.loads((OUTPUT / "woods-runtime-files.json").read_text()).items():
        if digest(RUNTIME / path) != sha:
            raise SystemExit(f"Pinned Woods runtime changed: {path}")
    cases = json.loads((OUTPUT / "cases.json").read_text())
    if only and set(only) - {case["id"] for case in cases}:
        raise SystemExit("Unknown --only candidate")
    selected = [case for case in cases if not only or case["id"] in only]
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        receipts = list(pool.map(run_case, selected))
    save_json(OUTPUT / "app-runs.json", receipts)
    if any(receipt["exit_code"] for receipt in receipts):
        raise SystemExit("A candidate failed; inspect its raw log")
    checks = []
    for case in selected:
        evidence = json.loads((OUTPUT / "results" / f"{case['id']}-evidence.json").read_text())
        oracle = json.loads((OUTPUT / "results" / f"{case['id']}-oracle.json").read_text())
        assert evidence["freshness"]["state"] == "current"
        assert evidence["checked_out_sha"] == case["head"] and evidence["working_tree"] == []
        assert oracle["oracle_matches_intended_case"]
        for card in case["cards"]:
            assert evidence["source_hashes"][card["path"]] == card["sha256"]
            assert evidence["source_files"][card["path"]] == card["source"]
        checks.append({"id": case["id"], "generation": evidence["generation"], "freshness": "current",
                       "source_hashes_match": True, "oracle_matches": True,
                       "ordinary_spec_passed": True, "necessary_card_count": len(case["necessary_card_ids"])})
    paired = []
    for family in sorted({case["family"] for case in selected}):
        pair = [case for case in selected if case["family"] == family]
        if len(pair) == 2:
            left, right = pair
            paired.append({"family": family, "initial_diff_equal": left["diff"] == right["diff"],
                           "initial_source_equal": (Path(left["app_path"]) / left["path"]).read_text() == (Path(right["app_path"]) / right["path"]).read_text(),
                           "menu_equal": [{key: card[key] for key in ["id", "path", "kind"]} for card in left["cards"]] == [{key: card[key] for key in ["id", "path", "kind"]} for card in right["cards"]]})
    save_json(OUTPUT / "validation.json", {"cases": checks, "pairs": paired, "provider_calls": 0})
    print(f"Verified {len(checks)} clean, deep-current, executable-oracle cases", flush=True)


def main():
    global REPO, OUTPUT, TEMPLATE, RUNTIME, IMAGE, VOLUME, DOCKER, REVISION
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--woods-root", type=Path, default=REPO)
    parser.add_argument("--woods-revision", default=REVISION)
    parser.add_argument("--template", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", default=IMAGE)
    parser.add_argument("--bundle-volume", default=VOLUME)
    parser.add_argument("--docker-command", default="docker")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    REPO, OUTPUT = args.woods_root.resolve(), args.output.resolve()
    TEMPLATE = args.template.resolve() if args.template else None
    RUNTIME = OUTPUT / "woods-runtime"
    REVISION = git(REPO, "rev-parse", args.woods_revision)
    IMAGE, VOLUME, DOCKER = args.image, args.bundle_volume, shlex.split(args.docker_command)
    if not DOCKER or args.jobs < 1:
        parser.error("Docker command and positive job count are required")
    if TEMPLATE and (OUTPUT == TEMPLATE or OUTPUT.is_relative_to(TEMPLATE) or TEMPLATE.is_relative_to(OUTPUT)):
        parser.error("Template and output must be separate directories")
    if not args.prepare and not args.run:
        args.prepare = args.run = True
    if args.prepare:
        prepare()
    if args.run:
        run(args.jobs, args.only)


if __name__ == "__main__":
    main()
