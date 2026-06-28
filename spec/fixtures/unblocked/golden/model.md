# Order (model)
**File:** `app/models/order.rb` | **LOC:** 142 | **Table:** orders | (11 columns)

## Associations (4)
**belongs_to:** User
**has_many:** LineItem (destroy), Payment
**has_one:** Invoice (nullify)

## Dependents (5 units)
2 controllers, 1 graphql_types, 1 jobs, 1 mailers

## Entry Points
**Controllers:** Admin::OrdersController, OrdersController
**GraphQL:** Types::OrderType
**Jobs:** FulfillOrderJob

## Schema Highlights
**Enums:** status (pending, paid, shipped, cancelled, refunded)
**Scopes:** paid, pending, recent
**Concerns:** Auditable, Timestamps
**Callbacks (2):** after_commit: notify_user, before_save: normalize_total

## Side Effects
**Jobs:** FulfillOrderJob
**Mailers:** OrderMailer