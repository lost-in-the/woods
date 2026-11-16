# frozen_string_literal: true

Rails.application.routes.draw do
  resources :items, only: %i[index show create update destroy edit] do
    post :archive, on: :member
    get :summary, on: :collection
    get :export, on: :collection
    get :preview, on: :collection
  end
end
