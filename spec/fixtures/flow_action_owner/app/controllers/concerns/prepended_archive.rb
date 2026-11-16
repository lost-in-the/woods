# frozen_string_literal: true

module PrependedArchive
  def archive
    PrependedArchiveJob.perform_later
    super
  end
end
