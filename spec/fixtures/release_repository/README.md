# Woods (release fixture)

A canned stand-in for the repository README. The release specs rewrite these
fences instead of the checked-in ones, so they behave the same whether the tree
they run in is an alpha, a prerelease, or a final release.

[![Gem Version](https://img.shields.io/gem/v/woods)](https://rubygems.org/gems/woods)

<!-- release-state:version-banner -->
> **This tree documents version 2.0.0.** It is a major update from 1.x: read [what changed and how to upgrade](docs/UPGRADING_TO_2.md) before updating. The full history is in the [CHANGELOG](CHANGELOG.md).
>
> `main` is the development branch and can run ahead of the latest published gem. The gem badge above shows the latest published version; documentation for a published version lives on its tag.
>
> ### Version: `main` documents 2.0.0, which is not released yet
>
> | Line | Version | Documentation |
> |---|---|---|
> | Documented here | **2.0.0**, unreleased | this README and the [documentation index](docs/README.md) |
> | Latest published gem | **1.6.1** | [the v1.6.1 tag](https://github.com/lost-in-the/woods/tree/v1.6.1) |
>
> Everything below describes 2.0.0. `gem "woods", "~> 2.0"` does not resolve from RubyGems until 2.0.0 is published. The released constraint stays `gem "woods", "~> 1.6"`.
<!-- release-state:end -->

Woods boots a Rails app, extracts the behavior Rails assembles at runtime, and
serves it to AI tools through the Model Context Protocol.
