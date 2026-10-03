- Validator-to-validator edges keep the referenced validator's full
  constant path (`Cart::ShippableValidator`) instead of only its last
  segment, so they resolve to the namespaced validator unit.
