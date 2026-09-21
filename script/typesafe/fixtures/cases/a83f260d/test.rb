# frozen_string_literal: true

routes = FixtureRoutes.new('books' => { controller: 'BooksController', action: 'index' })
raise 'known route unavailable' unless routes.resolve_route_helper('books_path')[:action] == 'index'
raise 'unknown helper accepted' unless routes.resolve_route_helper('asset_url').nil?
