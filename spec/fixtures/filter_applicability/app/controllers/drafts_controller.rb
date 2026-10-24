# frozen_string_literal: true

# Narrows the inherited only: %i[show edit] scope to show: Rails runs
# set_article where both scopes admit the action.
class DraftsController < ArticlesController
  skip_before_action :set_article, except: :show
end
