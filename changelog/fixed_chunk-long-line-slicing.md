- Slice a source line longer than 100,000 characters when the chunk ceiling
  is itself above 100,000. The slicer built a `.{1,N}` pattern, which the
  regex engine refuses for `N` over 100,000, so embedding such a unit raised
  `RegexpError`.
