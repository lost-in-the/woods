#!/usr/bin/env python3
"""Build and execute isolated, booted Rails bank fixtures; never invokes Jev.

The source template is the disposable base made by build_original_pairs.py.
Fixture applications, ordinary spec logs, fresh Woods evidence, and private
oracles live in the ignored output directory. No oracle enters evidence JSON.
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
import time


REPO = Path(__file__).resolve().parents[3]
OUTPUT = None
TEMPLATE = None
IMAGE = "woods-testbed-rails-8.0-large:latest"
VOLUME = "woods-testbed-bundle-rails-8-large"
DOCKER_COMMAND = ["docker"]


def write(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)


def ruby(source):
    return "# frozen_string_literal: true\n\n" + source


def save_json(path, value):
    write(path, json.dumps(value, indent=2) + "\n")


def git(app, *args):
    return subprocess.check_output(["git", "-C", str(app), *args], text=True).strip()


def docker(app, script, name):
    return [
        *DOCKER_COMMAND, "run", "--rm", "--pull=never", "--name", name,
        "--user", f"{os.getuid()}:{os.getgid()}", "--entrypoint", "bash",
        "-e", "BUNDLE_APP_CONFIG=/app/.bundle", "-e", "RAILS_ENV=test",
        "-e", "SECRET_KEY_BASE=woods-disposable-review-bank",
        "-e", f"PILOT_CASE={app.name}",
        "-v", f"{VOLUME}:/bundle:ro", "-v", f"{app}:/app",
        "-v", f"{REPO}:/woods-gem:ro", "-v", f"{OUTPUT}:/evaluation",
        IMAGE, "-lc", script,
    ]


COMMON = {
    "app/models/review_invitation.rb": ruby("""class ReviewInvitation < ApplicationRecord
end
"""),
    "app/models/review_owner.rb": ruby("""class ReviewOwner < ApplicationRecord
end
"""),
    "app/models/review_document.rb": ruby("""class ReviewDocument < ApplicationRecord
  belongs_to :owner, class_name: 'ReviewOwner', optional: true
  default_scope { where(archived: false) }
end
"""),
    "app/models/review_product.rb": ruby("""class ReviewProduct < ApplicationRecord
end
"""),
    "app/models/review_wallet.rb": ruby("""class ReviewWallet < ApplicationRecord
  validates :balance, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: :limit }
end
"""),
    "app/services/review_archive.rb": ruby("""class ReviewArchive
  def self.call(document)
    document.update!(archived: true)
  end
end
"""),
    "app/controllers/review_documents_controller.rb": ruby("""class ReviewDocumentsController < ActionController::Base
  before_action :require_authenticated_identity
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def show
    document = ReviewDocumentFinder.new(request.get_header('review.reviewer_id')).call(params[:id])
    render json: { title: document.title }
  end

  private

  def require_authenticated_identity
    head :unauthorized unless request.get_header('review.reviewer_id')
  end

  def not_found
    head :not_found
  end
end
"""),
    "db/migrate/20260921000003_create_review_bank_tables.rb": ruby("""class CreateReviewBankTables < ActiveRecord::Migration[8.0]
  def change
    create_table :review_invitations do |t|
      t.string :token, null: false
    end
    add_index :review_invitations, :token, unique: true
    create_table :review_owners do |t|
      t.string :name, null: false
    end
    create_table :review_documents do |t|
      t.string :title, null: false
      t.boolean :archived, null: false, default: false
      t.integer :reviewer_id, null: false, default: 1
      t.references :owner, foreign_key: { to_table: :review_owners, on_delete: :nullify }
    end
    add_index :review_documents, :reviewer_id
    create_table :review_products do |t|
      t.integer :price_cents, null: false
      t.timestamps
    end
    create_table :review_wallets do |t|
      t.integer :balance, null: false, default: 0
      t.integer :limit, null: false, default: 1000
    end
  end
end
"""),
    "config/initializers/review_bank.rb": ruby("""Rails.application.config.cache_store = :memory_store
Rails.cache = ActiveSupport::Cache::MemoryStore.new
"""),
}


def spec(klass, description, body):
    return ruby(f"require 'rails_helper'\n\nRSpec.describe {klass} do\n  it '{description}' do\n{body}\n  end\nend\n")


def definitions():
    """Frozen pair order: first five development, last three held out."""
    return [
        {
            "family": "nil_memoization", "target_question_ids": ["ar_find_by_memoized"],
            "brief": "An invitation lookup object is shared by multiple presenter calls during one request. Resolve its token once, including an absent invitation, so repeated access does not repeat the database lookup.",
            "path": "app/services/review_invitation_lookup.rb",
            "variants": [ruby("""class ReviewInvitationLookup
  def initialize(token)
    @token = token
  end

  def invitation
    @invitation ||= ReviewInvitation.find_by(token: @token)
  end
end
"""), ruby("""class ReviewInvitationLookup
  def initialize(token)
    @token = token
  end

  def invitation
    return @invitation if defined?(@invitation)

    @invitation = ReviewInvitation.find_by(token: @token)
  end
end
""")],
            "support": ["app/models/review_invitation.rb"],
            "identities": [["ReviewInvitationLookup", "service"], ["ReviewInvitation", "model"]],
            "test": spec("ReviewInvitationLookup", "returns the invitation associated with a known token", """    invitation = ReviewInvitation.create!(token: 'event-invitation')
    lookup = described_class.new(invitation.token)
    expect(lookup.invitation).to eq(invitation)
    expect(lookup.invitation).to eq(invitation)"""),
        },
        {
            "family": "default_scope", "target_question_ids": ["ar_default_scope", "disposition"],
            "brief": "List active document titles alphabetically. ReviewDocument's existing default scope intentionally excludes archived documents from ordinary readers; this endpoint must retain that established visibility rule.",
            "path": "app/services/review_document_list.rb",
            "variants": [ruby("""class ReviewDocumentList
  def self.call
    ReviewDocument.unscoped.order(:title).pluck(:title)
  end
end
"""), ruby("""class ReviewDocumentList
  def self.call
    ReviewDocument.order(:title).pluck(:title)
  end
end
""")],
            "support": ["app/models/review_document.rb", "app/models/review_owner.rb"],
            "identities": [["ReviewDocumentList", "service"], ["ReviewDocument", "model"]],
            "test": spec("ReviewDocumentList", "lists active titles alphabetically", """    ReviewDocument.create!(title: 'Zebra')
    ReviewDocument.create!(title: 'Apple')
    expect(described_class.call).to eq(%w[Apple Zebra])"""),
            "question_caveat": "ar_default_scope is a convention/fact: the default scope is unchanged and legitimate in both candidates. Runtime defect label concerns removal of its visibility filter, not default_scope use.",
        },
        {
            "family": "cache_invalidation", "target_question_ids": ["perf_cache_without_invalidation"],
            "brief": "Cache a formatted price card for repeated reads while returning the current amount immediately after a product price update. The cache is a process-local MemoryStore and no external invalidation hooks exist.",
            "path": "app/services/review_price_card.rb",
            "variants": [ruby("""class ReviewPriceCard
  def self.call(product)
    Rails.cache.fetch(['price-card', product.id]) do
      { product_id: product.id, price_cents: product.price_cents }
    end
  end
end
"""), ruby("""class ReviewPriceCard
  def self.call(product)
    Rails.cache.fetch(['price-card', product]) do
      { product_id: product.id, price_cents: product.price_cents }
    end
  end
end
""")],
            "support": ["app/models/review_product.rb", "config/initializers/review_bank.rb"],
            "identities": [["ReviewPriceCard", "service"], ["ReviewProduct", "model"]],
            "test": spec("ReviewPriceCard", "returns the current product price", """    Rails.cache.clear
    product = ReviewProduct.create!(price_cents: 1250)
    expect(described_class.call(product)).to eq(product_id: product.id, price_cents: 1250)"""),
        },
        {
            "family": "unbounded_loading", "target_question_ids": ["vm_unbatched_collection", "vm_memory_impact"],
            "brief": "Stream every document, including archives, to the supplied writer in primary-key order. The export may contain millions of rows, so database record instantiation must remain bounded to at most 25 records per batch; the writer consumes one record at a time.",
            "path": "app/services/review_document_export.rb",
            "variants": [ruby("""class ReviewDocumentExport
  BATCH_SIZE = 25

  def self.call(writer)
    ReviewDocument.unscoped.order(:id).each { |document| writer.call(document) }
  end
end
"""), ruby("""class ReviewDocumentExport
  BATCH_SIZE = 25

  def self.call(writer)
    ReviewDocument.unscoped.find_each(batch_size: BATCH_SIZE) { |document| writer.call(document) }
  end
end
""")],
            "support": ["app/models/review_document.rb", "app/models/review_owner.rb"],
            "identities": [["ReviewDocumentExport", "service"], ["ReviewDocument", "model"]],
            "test": spec("ReviewDocumentExport", "streams active and archived documents to the writer", """    active = ReviewDocument.create!(title: 'Active')
    archived = ReviewDocument.create!(title: 'Archived', archived: true)
    output = []
    described_class.call(->(document) { output << document.title })
    expect(output).to eq([active.title, archived.title])"""),
        },
        {
            "family": "association_preloading", "target_question_ids": ["perf_n_plus_one", "perf_query_in_loop"],
            "brief": "Build up to 20 document-owner rows. Owner names come from the belongs_to association; owner lookup query count must stay constant as the number of returned documents grows.",
            "path": "app/services/review_owner_rows.rb",
            "variants": [ruby("""class ReviewOwnerRows
  def self.call
    ReviewDocument.where.not(owner_id: nil).order(:id).limit(20).map do |document|
      [document.title, document.owner.name]
    end
  end
end
"""), ruby("""class ReviewOwnerRows
  def self.call
    ReviewDocument.where.not(owner_id: nil).includes(:owner).order(:id).limit(20).map do |document|
      [document.title, document.owner.name]
    end
  end
end
""")],
            "support": ["app/models/review_document.rb", "app/models/review_owner.rb"],
            "identities": [["ReviewOwnerRows", "service"], ["ReviewDocument", "model"], ["ReviewOwner", "model"]],
            "test": spec("ReviewOwnerRows", "returns each document with its owner name", """    owner = ReviewOwner.create!(name: 'Alex')
    ReviewDocument.create!(title: 'Agenda', owner: owner)
    expect(described_class.call).to eq([['Agenda', 'Alex']])"""),
        },
        {
            "family": "tenant_lookup", "target_question_ids": ["sec_unscoped_lookup", "sec_worst_case_impact"],
            "brief": "The show endpoint accepts a document ID but may return only an active document belonging to the authenticated reviewer. A trusted upstream authentication boundary supplies review.reviewer_id in Rack env; clients cannot set that Rack field. Foreign and missing document IDs both return 404.",
            "path": "app/services/review_document_finder.rb",
            "variants": [ruby("""class ReviewDocumentFinder
  def initialize(reviewer_id)
    @reviewer_id = reviewer_id
  end

  def call(document_id)
    ReviewDocument.find(document_id)
  end
end
"""), ruby("""class ReviewDocumentFinder
  def initialize(reviewer_id)
    @reviewer_id = reviewer_id
  end

  def call(document_id)
    ReviewDocument.where(reviewer_id: @reviewer_id).find(document_id)
  end
end
""")],
            "support": ["app/models/review_document.rb", "app/models/review_owner.rb", "app/controllers/review_documents_controller.rb", "config/routes.rb"],
            "identities": [["ReviewDocumentFinder", "service"], ["ReviewDocument", "model"], ["ReviewDocumentsController", "controller"]],
            "test": spec("ReviewDocumentFinder", "finds an active document belonging to the reviewer", """    document = ReviewDocument.create!(title: 'Personal agenda', reviewer_id: 7)
    expect(described_class.new(7).call(document.id)).to eq(document)"""),
        },
        {
            "family": "test_effectiveness", "target_question_ids": ["test_cannot_fail", "test_coverage_of_change"],
            "brief": "Add a regression example showing that archiving persists the archived flag in the database. The example must reject a service that returns normally but does not persist the requested change.",
            "path": "spec/services/review_archive_spec.rb",
            "variants": [spec("ReviewArchive", "persists the archived flag", """    document = ReviewDocument.create!(title: 'Agenda')
    described_class.call(document)
    expect(true).to be(true)"""), spec("ReviewArchive", "persists the archived flag", """    document = ReviewDocument.create!(title: 'Agenda')
    described_class.call(document)
    expect(document.reload.archived).to be(true)""")],
            "support": ["app/services/review_archive.rb", "app/models/review_document.rb", "app/models/review_owner.rb"],
            "identities": [["ReviewArchive", "service"], ["ReviewDocument", "model"]],
        },
        {
            "family": "atomic_writes", "target_question_ids": ["db_writes_not_atomic"],
            "brief": "Move credits between two wallets. If the destination exceeds its configured balance limit, validation rejects the transfer and neither wallet may retain any balance change. Successful transfers debit and credit the same amount.",
            "path": "app/services/review_credit_transfer.rb",
            "variants": [ruby("""class ReviewCreditTransfer
  def self.call(source, destination, amount)
    source.update!(balance: source.balance - amount)
    destination.update!(balance: destination.balance + amount)
  end
end
"""), ruby("""class ReviewCreditTransfer
  def self.call(source, destination, amount)
    ReviewWallet.transaction do
      source.update!(balance: source.balance - amount)
      destination.update!(balance: destination.balance + amount)
    end
  end
end
""")],
            "support": ["app/models/review_wallet.rb"],
            "identities": [["ReviewCreditTransfer", "service"], ["ReviewWallet", "model"]],
            "test": spec("ReviewCreditTransfer", "moves credits between wallets", """    source = ReviewWallet.create!(balance: 100, limit: 1000)
    destination = ReviewWallet.create!(balance: 25, limit: 1000)
    described_class.call(source, destination, 10)
    expect([source.reload.balance, destination.reload.balance]).to eq([90, 35])"""),
        },
    ]


COLLECTOR = ruby(r"""require 'json'
require 'digest'
require 'woods/published_index'
require 'woods/source_inputs/status'
cid = ENV.fetch('PILOT_CASE')
item = JSON.parse(File.read('/evaluation/cases.json')).find { |row| row['id'] == cid }
index_dir = Rails.root.join('tmp/woods')
Woods::PublishedIndex.open(index_dir) do |index|
  entries = index.units.select { |entry| item['identities'].any? { |identifier, _| identifier == entry['identifier'] } }
  units = entries.map { |entry| index.unit(entry['identifier'], type: entry['type']) }.compact
  wanted = units.map { |unit| unit['identifier'] }
  files = ([item['path']] + item['support']).uniq
  packet = {
    generation: index.generation_number, manifest: index.manifest,
    freshness: Woods::SourceInputs::Status.new(output_dir: index_dir, payload_dir: index.payload_dir,
      generation: index.generation_number, mode: 'deep').call,
    units: units,
    relationships: index.edges.select { |edge| wanted.include?(edge[:from]) || wanted.include?(edge[:to]) },
    runtime: { rails_version: Rails.version, ruby_version: RUBY_VERSION,
      database: ActiveRecord::Base.connection.adapter_name, cache_store: Rails.cache.class.name,
      active_job_adapter: Rails.application.config.active_job.queue_adapter,
      authenticated_identity: 'Trusted upstream Rack env review.reviewer_id; absent identity yields 401' },
    source_files: files.to_h { |path| [path, File.read(Rails.root.join(path))] },
    source_hashes: files.to_h { |path| [path, Digest::SHA256.file(Rails.root.join(path)).hexdigest] },
    checked_out_sha: `git rev-parse HEAD`.strip, working_tree: `git status --porcelain`.lines,
    index_checksum: index.external_dependency_checksum
  }
  raise "Index not current: #{packet[:freshness]}" unless packet[:freshness][:state] == 'current' || packet[:freshness]['state'] == 'current'
  raise 'Application worktree changed' unless packet[:working_tree].empty?
  raise 'Candidate revision differs' unless packet[:checked_out_sha] == item['head']
  File.write("/evaluation/results/#{cid}-evidence.json", JSON.pretty_generate(packet))
end
""")

ORACLE = ruby(r"""require 'json'
cid = ENV.fetch('PILOT_CASE')
item = JSON.parse(File.read('/evaluation/cases.json')).find { |row| row['id'] == cid }
result = { case_id: cid, family: item['family'] }
def sql_reads(table)
  reads = []
  subscriber = ->(*args) do
    event = args.last
    reads << event[:sql] if !event[:cached] && event[:sql].match?(/\ASELECT/i) && event[:sql].include?(%Q("#{table}"))
  end
  ActiveRecord::Base.uncached do
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
  end
  reads
end
case item['family']
when 'nil_memoization'
  missing = ReviewInvitationLookup.new('absent-invitation')
  values = []
  reads = sql_reads('review_invitations') { 3.times { values << missing.invitation } }
  present = ReviewInvitation.create!(token: 'present-invitation')
  found = ReviewInvitationLookup.new(present.token)
  positive = []
  present_reads = sql_reads('review_invitations') { 3.times { positive << found.invitation&.id } }
  result.merge!(missing_values: values, missing_read_count: reads.size, present_read_count: present_reads.size,
    observed_sql: reads, contract_holds: values == [nil, nil, nil] && reads.size == 1 && present_reads.size == 1 && positive == [present.id] * 3)
when 'default_scope'
  ReviewDocument.create!(title: 'Active')
  ReviewDocument.create!(title: 'Archived', archived: true)
  actual = ReviewDocumentList.call
  result.merge!(returned_titles: actual, contract_holds: actual == ['Active'])
when 'cache_invalidation'
  Rails.cache.clear
  product = ReviewProduct.create!(price_cents: 1200)
  first = ReviewPriceCard.call(product)
  product.update!(price_cents: 1900, updated_at: product.updated_at + 10.seconds)
  second = ReviewPriceCard.call(product.reload)
  result.merge!(before: first, after: second, contract_holds: first[:price_cents] == 1200 && second[:price_cents] == 1900)
when 'unbounded_loading'
  80.times { |i| ReviewDocument.create!(title: "Document #{i}", archived: i.odd?) }
  expected = ReviewDocument.unscoped.order(:id).pluck(:id)
  instantiations = []
  observed = []
  observer = ->(*args) { data = args.last; instantiations << data[:record_count] if data[:class_name] == 'ReviewDocument' }
  ActiveSupport::Notifications.subscribed(observer, 'instantiation.active_record') do
    ReviewDocumentExport.call(->(document) { observed << document.id })
  end
  result.merge!(instantiation_batches: instantiations, delivered_rows: observed.size,
    contract_holds: observed == expected && instantiations.any? && instantiations.max <= 25)
when 'association_preloading'
  8.times do |i|
    owner = ReviewOwner.create!(name: "Owner #{i}")
    ReviewDocument.create!(title: "Document #{i}", owner: owner)
  end
  rows = nil
  reads = sql_reads('review_owners') { rows = ReviewOwnerRows.call }
  expected = 8.times.map { |i| ["Document #{i}", "Owner #{i}"] }
  result.merge!(owner_read_count: reads.size, observed_sql: reads, rows: rows,
    contract_holds: rows == expected && reads.size == 1)
when 'tenant_lookup'
  owned = ReviewDocument.create!(title: 'Own document', reviewer_id: 7)
  foreign = ReviewDocument.create!(title: 'Foreign document', reviewer_id: 9)
  client = ActionDispatch::Integration::Session.new(Rails.application)
  statuses = {}
  [[:own, owned.id], [:foreign, foreign.id], [:missing, foreign.id + 1000]].each do |name, id|
    client.get("/review_bank/documents/#{id}", env: { 'review.reviewer_id' => 7 })
    statuses[name] = client.response.status
  end
  client.get("/review_bank/documents/#{owned.id}")
  statuses[:anonymous] = client.response.status
  result.merge!(statuses: statuses, contract_holds: statuses == { own: 200, foreign: 404, missing: 404, anonymous: 401 })
when 'test_effectiveness'
  baseline_ok = system('bundle', 'exec', 'rspec', item['path'], '--format', 'documentation',
    out: "/evaluation/results/#{cid}-ordinary-spec.log", err: [:child, :out])
  mutant_ok = system('bundle', 'exec', 'rspec', '--require', '/evaluation/extra_mutant.rb', item['path'], '--format', 'documentation',
    out: "/evaluation/results/#{cid}-mutation-spec.log", err: [:child, :out])
  result.merge!(ordinary_spec_passed: baseline_ok, no_persistence_mutant_rejected: !mutant_ok,
    contract_holds: baseline_ok && !mutant_ok)
when 'atomic_writes'
  source = ReviewWallet.create!(balance: 100, limit: 1000)
  destination = ReviewWallet.create!(balance: 95, limit: 100)
  rejected = false
  begin
    ReviewCreditTransfer.call(source, destination, 10)
  rescue ActiveRecord::RecordInvalid
    rejected = true
  end
  actual = [source.reload.balance, destination.reload.balance]
  result.merge!(destination_validation_rejected: rejected, persisted_balances: actual,
    contract_holds: rejected && actual == [100, 95])
end
result[:expected_contract_holds] = !item['defect']
result[:oracle_matches_intended_case] = result[:contract_holds] == result[:expected_contract_holds]
File.write("/evaluation/results/#{cid}-oracle.json", JSON.pretty_generate(result))
puts JSON.generate(result)
raise 'Oracle does not match intended mechanism' unless result[:oracle_matches_intended_case]
""")

MUTANT = ruby("""require '/app/config/environment'
module ReviewArchiveWithoutPersistence
  def call(document)
    document.archived = true
  end
end
ReviewArchive.singleton_class.prepend(ReviewArchiveWithoutPersistence)
""")


def prepare():
    if TEMPLATE is None or not (TEMPLATE / "db/test.sqlite3").is_file():
        raise SystemExit("--template must name the disposable base produced by build_original_pairs.py")
    base = OUTPUT / "base"
    if base.exists():
        raise SystemExit("Refusing to overwrite a prepared bank; use --run to resume execution")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "results").mkdir(exist_ok=True)
    shutil.copytree(TEMPLATE, base, ignore=shutil.ignore_patterns("tmp", "log", ".git", "*.sqlite3", "*.sqlite3-*"))
    shutil.copy2(TEMPLATE / "db/test.sqlite3", base / "db/test.sqlite3")
    for directory in ["tmp", "log"]:
        (base / directory).mkdir(exist_ok=True)
    for path, content in COMMON.items():
        write(base / path, content)
    with (base / "config/routes.rb").open("a") as stream:
        stream.write("\nRails.application.routes.draw do\n  get '/review_bank/documents/:id', to: 'review_documents#show'\nend\n")
    pairs = definitions()
    for pair in pairs:
        if pair["path"].startswith("app/"):
            class_name = pair["identities"][0][0]
            write(base / pair["path"], ruby(f"class {class_name}\nend\n"))
        else:
            write(base / pair["path"], ruby("require 'rails_helper'\n\nRSpec.describe ReviewArchive do\nend\n"))
    migration_cmd = docker(base, "bundle exec rails db:migrate", "woods-bank-extra-prepare")
    with (OUTPUT / "prepare.log").open("w") as stream:
        subprocess.run(migration_cmd, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=240)
    git(base, "init", "-q")
    git(base, "config", "user.name", "Woods Evaluation")
    git(base, "config", "user.email", "evaluation@example.invalid")
    git(base, "add", ".")
    git(base, "commit", "-qm", "Application baseline for isolated Rails review")
    base_sha = git(base, "rev-parse", "HEAD")
    cases = []
    for position, pair in enumerate(pairs):
        for variant, content in enumerate(pair["variants"]):
            cid = hashlib.sha256(f"rails-bank-20260921:{position}:{variant}".encode()).hexdigest()[:8]
            app = OUTPUT / "apps" / cid
            shutil.copytree(base, app, ignore=shutil.ignore_patterns("tmp", "log", "*.sqlite3-*"))
            for directory in ["tmp", "log"]:
                (app / directory).mkdir(exist_ok=True)
            write(app / pair["path"], content)
            support = list(pair["support"])
            test_path = pair["path"] if pair["path"].startswith("spec/") else f"spec/services/{Path(pair['path']).stem}_spec.rb"
            changed_paths = [pair["path"]]
            if "test" in pair:
                write(app / test_path, pair["test"])
                support.append(test_path)
                changed_paths.append(test_path)
            support.extend(["spec/rails_helper.rb", "spec/support/canopy_context.rb", "db/migrate/20260921000003_create_review_bank_tables.rb"])
            git(app, "add", *changed_paths)
            git(app, "commit", "-qm", "Candidate application change")
            head = git(app, "rev-parse", "HEAD")
            case = {k: v for k, v in pair.items() if k not in ["variants", "test"]}
            case.update(id=cid, pair_id=f"extra-{position + 1:02}", defect=variant == 0,
                        split="development" if position < 5 else "holdout", support=support,
                        base=base_sha, head=head, app_path=str(app), test_path=test_path,
                        changed_paths=changed_paths,
                        diff=git(app, "diff", "--no-ext-diff", "--unified=8", base_sha, head, "--", *changed_paths))
            cases.append(case)
    random.Random(20260921).shuffle(cases)
    save_json(OUTPUT / "cases.json", cases)
    write(OUTPUT / "extra_collect.rb", COLLECTOR)
    write(OUTPUT / "extra_oracle.rb", ORACLE)
    write(OUTPUT / "extra_mutant.rb", MUTANT)
    save_json(OUTPUT / "fixture-freeze.json", {
        "frozen_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "woods_head": git(REPO, "rev-parse", "HEAD"), "base": base_sha,
        "cases_sha256": hashlib.sha256((OUTPUT / "cases.json").read_bytes()).hexdigest(),
        "builder_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "holdout_cases": [c["id"] for c in cases if c["split"] == "holdout"],
        "holdout_pairs": ["extra-06", "extra-07", "extra-08"],
        "inference_calls": 0,
        "holdout_policy": "Assignment fixed before any Jev inference; do not tune questions or routing on these cases.",
    })
    save_json(OUTPUT / "preparation-receipt.json", {
        "source_template": str(TEMPLATE), "original_testbed_touched": False,
        "docker_image": IMAGE, "bundle_volume": VOLUME,
        "migration_command": migration_cmd, "case_count": len(cases),
        "database": "Independent copied SQLite database per case, migrated before source baseline commit",
        "extraction": "bundle exec ruby -I/woods-gem/lib /woods-gem/exe/woods-extract full",
        "collector_sha256": hashlib.sha256(COLLECTOR.encode()).hexdigest(),
        "oracle_sha256": hashlib.sha256(ORACLE.encode()).hexdigest(),
    })
    print(f"Prepared {len(cases)} cases: {OUTPUT / 'cases.json'}", flush=True)


def run_case(case):
    cid = case["id"]
    app = Path(case["app_path"])
    if git(app, "status", "--porcelain"):
        raise RuntimeError(f"Refusing to execute modified candidate {cid}")
    # Oracle writes belong to the fixture database, never to a later repeat.
    # Remove only this generated application's disposable database sidecars and
    # generated index, then restore the migrated, empty baseline database.
    for sidecar in (app / "db").glob("test.sqlite3-*"):
        sidecar.unlink()
    shutil.copy2(OUTPUT / "base/db/test.sqlite3", app / "db/test.sqlite3")
    if (app / "tmp/woods").exists():
        shutil.rmtree(app / "tmp/woods")
    # Separate boots: ordinary tests, extraction through the installed launcher,
    # read-only evidence collection, and only then private oracle writes.
    steps = [
        f"bundle exec rspec {case['test_path']} --format documentation",
        "bundle exec ruby -I/woods-gem/lib /woods-gem/exe/woods-extract full",
        "bundle exec rails runner /evaluation/extra_collect.rb",
        "bundle exec rails runner /evaluation/extra_oracle.rb",
    ]
    command = docker(app, " && ".join(steps), f"woods-bank-extra-{cid}")
    started = time.monotonic()
    with (OUTPUT / "results" / f"{cid}.log").open("w") as stream:
        completed = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
    receipt = {"id": cid, "exit_code": completed.returncode, "seconds": time.monotonic() - started,
               "command": command, "steps": steps}
    save_json(OUTPUT / "results" / f"{cid}-run.json", receipt)
    print(json.dumps({k: receipt[k] for k in ["id", "exit_code", "seconds"]}), flush=True)
    return receipt


def run(jobs, only):
    cases = json.loads((OUTPUT / "cases.json").read_text())
    freeze = json.loads((OUTPUT / "fixture-freeze.json").read_text())
    if git(REPO, "rev-parse", "HEAD") != freeze["woods_head"]:
        raise SystemExit("Woods checkout changed since fixture freeze")
    selected = [c for c in cases if not only or c["id"] in only]
    if only and set(only) - {case["id"] for case in cases}:
        raise SystemExit("--only includes an unknown case ID")
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(run_case, selected))
    save_json(OUTPUT / "app-runs.json", results)
    if any(row["exit_code"] for row in results):
        raise SystemExit("One or more cases failed; inspect per-case logs")
    for case in selected:
        evidence = json.loads((OUTPUT / "results" / f"{case['id']}-evidence.json").read_text())
        oracle = json.loads((OUTPUT / "results" / f"{case['id']}-oracle.json").read_text())
        assert evidence["freshness"]["state"] == "current"
        assert evidence["checked_out_sha"] == case["head"] and not evidence["working_tree"]
        assert oracle["oracle_matches_intended_case"]
    print(f"Verified {len(selected)} fresh, oracle-confirmed cases", flush=True)


def main():
    global REPO, OUTPUT, TEMPLATE, IMAGE, VOLUME, DOCKER_COMMAND
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--woods-root", type=Path, default=REPO)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--template", type=Path, help="Original fixture output's base/ directory; required for preparation")
    parser.add_argument("--image", default=IMAGE)
    parser.add_argument("--bundle-volume", default=VOLUME)
    parser.add_argument("--docker-command", default="docker", help="Docker command prefix, e.g. 'sudo -n docker'")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    REPO, OUTPUT = args.woods_root.resolve(), args.output.resolve()
    TEMPLATE = args.template.resolve() if args.template else None
    IMAGE, VOLUME, DOCKER_COMMAND = args.image, args.bundle_volume, shlex.split(args.docker_command)
    if not DOCKER_COMMAND:
        parser.error("--docker-command cannot be empty")
    if not (REPO / "exe/woods-extract").is_file():
        parser.error("--woods-root must name a Woods source checkout")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if TEMPLATE is not None and (OUTPUT == TEMPLATE or OUTPUT.is_relative_to(TEMPLATE) or TEMPLATE.is_relative_to(OUTPUT)):
        parser.error("--output and --template must be separate directories")
    if not args.prepare and not args.run:
        args.prepare = args.run = True
    if args.prepare:
        prepare()
    if args.run:
        run(args.jobs, args.only)


if __name__ == "__main__":
    main()
