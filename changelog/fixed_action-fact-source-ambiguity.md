- Omit action facts when Ruby's line-only source location can identify multiple
  bodies, including Proc-backed methods installed from another file and renamed
  Method objects. Compact definitions sharing a line with another definition,
  a block opening or a generated-method declaration are conservatively omitted;
  action names and ordinary definitions on separate lines remain available.
