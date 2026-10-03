- Emit a template's `view_render` edge only when the controller its directory
  names exists at runtime as an `ActionController::Base` or
  `ActionController::API` subclass. A mailer view directory links to its
  `ActionMailer::Base` subclass with a `:mailer` edge. Directories such as
  `shared/`, nested `layouts/`, or versioned API paths no longer produce edges
  to controllers that do not exist. This also removes those dangling edges
  from ERB templates.
