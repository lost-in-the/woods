# frozen_string_literal: true

# rubocop:disable Metrics/MethodLength -- these are static data fixtures, not logic

# Rich, representative units used by the DocumentBuilder golden-output specs
# (and the shared metadata-shape fixture). Exercised through the full body
# formatter so that any byte-level drift — from the B-057 UnitFacts refactor or
# anything else — is caught before it forces an Unblocked mass re-push.
module GoldenUnits
  module_function

  def all
    { 'model' => model, 'controller' => controller, 'graphql' => graphql, 'generic' => generic }
  end

  def model
    {
      'type' => 'model',
      'identifier' => 'Order',
      'file_path' => 'app/models/order.rb',
      'metadata' => {
        'loc' => 142,
        'table_name' => 'orders',
        'column_count' => 11,
        'associations' => [
          { 'type' => 'belongs_to', 'target' => 'User' },
          { 'type' => 'has_many', 'target' => 'LineItem', 'options' => { 'dependent' => 'destroy' } },
          { 'type' => 'has_many', 'target' => 'Payment' },
          { 'type' => 'has_one', 'target' => 'Invoice', 'options' => { 'dependent' => 'nullify' } }
        ],
        'enums' => { 'status' => %w[pending paid shipped cancelled refunded archived] },
        'scopes' => [{ 'name' => 'recent' }, { 'name' => 'pending' }, { 'name' => 'paid' }],
        'inlined_concerns' => %w[Auditable Timestamps],
        'callbacks' => [
          { 'type' => 'before_save', 'filter' => 'normalize_total' },
          { 'type' => 'after_commit', 'filter' => 'notify_user' }
        ]
      },
      'dependencies' => [
        { 'type' => 'model', 'target' => 'User', 'via' => 'belongs_to' }
      ],
      'dependents' => [
        { 'type' => 'controller', 'identifier' => 'OrdersController' },
        { 'type' => 'controller', 'identifier' => 'Admin::OrdersController' },
        { 'type' => 'job', 'identifier' => 'FulfillOrderJob' },
        { 'type' => 'mailer', 'identifier' => 'OrderMailer' },
        { 'type' => 'graphql_type', 'identifier' => 'Types::OrderType' }
      ]
    }
  end

  def controller
    {
      'type' => 'controller',
      'identifier' => 'OrdersController',
      'file_path' => 'app/controllers/orders_controller.rb',
      'metadata' => {
        'ancestors' => %w[OrdersController ApplicationController ActionController::Base],
        'routes' => {
          'index' => [{ 'verb' => 'GET', 'path' => '/orders' }],
          'show' => [{ 'verb' => 'GET', 'path' => '/orders/:id' }],
          'create' => [{ 'verb' => 'POST', 'path' => '/orders' }]
        }
      },
      'dependencies' => [
        { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' },
        { 'type' => 'service', 'target' => 'CheckoutService', 'via' => 'code_reference' }
      ],
      'dependents' => [
        { 'type' => 'view_template', 'identifier' => 'orders/index' },
        { 'type' => 'view_template', 'identifier' => 'orders/show' }
      ]
    }
  end

  def graphql
    {
      'type' => 'graphql_type',
      'identifier' => 'Types::OrderType',
      'file_path' => 'app/graphql/types/order_type.rb',
      'metadata' => {},
      'dependencies' => [{ 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }],
      'dependents' => [{ 'type' => 'graphql_type', 'identifier' => 'Types::QueryType' }]
    }
  end

  def generic
    {
      'type' => 'service',
      'identifier' => 'CheckoutService',
      'file_path' => 'app/services/checkout_service.rb',
      'metadata' => { 'loc' => 64 },
      'dependencies' => [
        { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' },
        { 'type' => 'model', 'target' => 'Payment', 'via' => 'code_reference' },
        { 'type' => 'service', 'target' => 'PricingService', 'via' => 'code_reference' }
      ],
      'dependents' => [
        { 'type' => 'controller', 'identifier' => 'OrdersController' },
        { 'type' => 'job', 'identifier' => 'CheckoutJob' }
      ]
    }
  end
end
# rubocop:enable Metrics/MethodLength
