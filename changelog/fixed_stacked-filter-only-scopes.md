- A controller or mailer filter whose `only` scope a `skip_before_action ..., except:` narrowed now publishes the
  actions both scopes name in `metadata[:filters]` `only` (an empty list when they share none), instead of every
  action either names. Request flows read that list, so they no longer show the filter on actions Rails skips it
  for. Run a full extraction to refresh retained indexes.
