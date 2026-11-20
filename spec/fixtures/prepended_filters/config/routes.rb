# frozen_string_literal: true

Rails.application.routes.draw do
  %i[ledgers receipts early_audits late_audits instruments appended_steps batches].each do |name|
    resources name, only: %i[index show]
  end
  %i[portal portal_documents portal_pages portal_previews].each do |name|
    resources name, only: %i[index show edit]
  end
end
