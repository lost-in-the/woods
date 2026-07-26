# frozen_string_literal: true

Rails.application.routes.draw do
  resources :posts do
    resources :comments, only: %i[create destroy]
  end
  resources :users, only: :show

  namespace :admin do
    get 'dashboard', to: 'dashboard#index'
    root 'dashboard#index'
  end

  root 'posts#index'
end
