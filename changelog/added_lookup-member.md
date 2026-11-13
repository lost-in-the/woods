- The Index Server's `lookup` answers one method of a unit. `PostsController#create` or `Post.recent`, when it is
  not itself a published unit and its owner is, returns that method's file and line range, its published source
  lines and source text, stated as a member of the owner unit (`_meta.member_of`), not a unit of its own. Lines come
  from the published method table, or a Prism walk of older units' source; a method inlined from a concern names the
  concern's file. An owner without the method still answers `not_found`, now saying the owner exists and the method
  is not in its published source. An identifier that is a published unit keeps resolving to it.
