# frozen_string_literal: true

Rails.application.routes.draw do
  resources :posts, only: %i[index show create]
  root 'posts#index'
end
