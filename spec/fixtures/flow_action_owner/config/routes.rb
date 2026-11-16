# frozen_string_literal: true

Rails.application.routes.draw { resources :items, only: %i[show create update destroy] }
