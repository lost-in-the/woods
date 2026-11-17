# frozen_string_literal: true

module ExportOverride
  # rubocop:disable-next Style/SingleLineMethods, Style/Semicolon, Lint/DuplicateMethods
  def export; FirstExportJob.perform_later; end; def export; SecondExportJob.perform_later; end
end
