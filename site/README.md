# Documentation site candidate (#502)

This is a local build and CI artifact candidate, with no deployment. Canonical
guides stay in `docs/`; `manifest.yml` selects and orders them by task. Nothing
changes the gem, root bundle, repository homepage, or release policy.

Jekyll 4.4.1 + Just the Docs 0.12.0 provide navigation, local Lunr search,
keyboard/mobile controls and code copying using the existing Ruby toolchain.
GFM and Rouge render Markdown and code. The checker validates **actual rendered
IDs and named HTML anchors**, including duplicate headings; this is not a claim
of universal GitHub anchor parity. Browser usability remains an acceptance gate.

## Build, check, serve

From the repository root, select **Ruby 3.4.x** (for example with `mise`) and
**Bundler 2.5.22**. CI uses Ruby 3.4, the newest patch `ruby/setup-ruby`
resolves. The independent `Gemfile` / `Gemfile.lock` bundle must not use the
root Gemfile or its ignored lockfile.

```bash
export BUNDLE_GEMFILE="$PWD/site/Gemfile"
export BUNDLE_PATH="$HOME/.cache/woods-docs/bundle"
export BUNDLE_IGNORE_CONFIG=1 BUNDLE_FROZEN=true
flock -n -E 75 ../.heavy.lock bundle install --jobs 2 --retry 1
bundle exec ruby site/build.rb --baseurl /woods
bundle exec ruby site/check.rb --baseurl /woods
flock -n -E 75 ../.heavy.lock bundle exec ruby site/serve.rb --baseurl /woods --port 4015
```

Open <http://localhost:4015/woods/>. Stop the server with Ctrl-C. Choose another
unused port with `--port`. Use `--baseurl ''` on build/check/serve for a root-mounted
candidate at <http://localhost:4015/>. The builds are independent under
`tmp/woods-docs/{root,woods}/`, including sources, caches, destinations and reports.
Generated sources and HTML remain untracked. Reserved-filename checks create a
disposable private Git repository, with a synthetic identity and signing disabled
only in those fixture processes. They do not commit or change Git settings in
this checkout. Build/check acquire the shared parent `../.heavy.lock`
nonblockingly; exit 75 means its owner is busy. Do not
delete the lock or launch competing jobs. `WOODS_DOCS_LOCK` selects an equivalent
lock on another machine (CI uses its runner temp directory).

Installation needs network access. `Gemfile.lock` includes generic Ruby and the
resolved native Linux/Darwin platform variants; this is not a tested platform
matrix. The local candidate was installed on x86_64 Linux with Ruby 3.3.13.
Jekyll Sass Converter 3 uses `sass-embedded`: binary availability, native builds
and the Sass runtime can affect install time. Retain install/build timings rather
than assuming it is cheap. Sass deprecation messages from the locked theme are
visible in build logs.

## Versions and source links

Each version has its own source directory, destination, base URL and search
index. `unreleased/` reads the working checkout and displays HEAD **plus dirty
status and a guide-content digest**; a SHA alone does not identify dirty text.
`v2.1.0/` reads only local Git objects at the exact tag pin
`cdd330f709cca9f47302390799641b986f08e213`. These choices establish no support policy.

The tag must already exist locally and peel to that commit. Missing/mismatched
objects fail. Every builder Git read disables lazy fetching, including in partial
clones. Obtain a missing tag explicitly outside the builder; the CI job performs
one narrow tag fetch and verifies the peeled SHA.

Guide basenames become URLs such as `unreleased/GETTING_STARTED.html`. The version
picker preserves a guide if present; otherwise it links to that version’s guide
list with an explanation. Historical omissions are expected and listed on that
landing page. Unreleased text is never substituted into a release guide.

Guide bodies receive generated `render_with_liquid: false` front matter in
staging. Theme layouts, includes and search assets still run Liquid. Rendered
`href`/`src` attributes resolve against original repository paths, including
same-repository `blob/main` links. Included guides stay version local; existing
excluded files/directories link to pinned repository sources. Missing targets
fail instead of becoming external links. Queries, fragments, escaping and
file/directory distinctions are checked. Code text is never rewritten.

Embedded repository assets referenced by `src`, or SVG `image`/`feImage`
`href`/`xlink:href`, are copied into each version's
`source-assets/` directory from that version's exact Git revision. This includes
the unreleased version: dirty guide text does not substitute dirty asset bytes.
Only referenced assets are copied; their SHA-256 values are recorded and checked
against local Git objects. Rendered image fixtures pass through this same build
and artifact checker. Resources referenced inside an asset's contents are not
recursively bundled; offline images must be self-contained. Encoded terminal
slashes still mean directories, and URL path components escape reserved filename
characters before the original query
and fragment are appended. HTML fragments are checked against rendered anchors;
image/media fragments retain their browser-defined meaning. Direct SVG image
attributes reject network resources, including pinned external URLs; ordinary
external anchor navigation and self-contained data images remain supported.

## Artifact and serving requirements

The single docs CI job caches the locked bundle, builds/checks both mounts and
uploads HTML, local theme assets, version-local search JSON and build/check logs.
It does not run a Rails matrix or publish a site or hosted PR preview.

Each staged version keeps Jekyll's disk cache in its own hidden `.jekyll-cache/`
directory, outside the public artifact. Before checking HTML, the checker walks
every public entry, including hidden files. It accepts only the hub pages and
public provenance record, declared version pages, the locked theme's asset paths,
and the exact recorded `source-assets/` paths. Unexpected cache, staged source,
configuration or log files fail; guide-linked code keeps its original path.

Serve the chosen `public/` directory at the **same base URL used to build it**.
Pages, self-contained repository images, theme assets and search work over local
HTTP without an internet connection after installation/build. Arbitrary network
`src` and stylesheet assets, including explicitly versioned remote images, fail
the checker; source images must use a relative, repository-root, or supported
same-repository `main` URL so they can be verified and staged. Following pinned
GitHub source links still needs the network; `file://` is not supported. Code
copying requires HTTPS or localhost.

Live resource attributes inside raw HTML `pre`/`code` formatting wrappers receive
the same rewriting and network checks. Escaped and fenced examples remain exact
copy text. The checker includes wrapped script/image negatives and local images.
It walks attribute objects so HTML `href`/`src` and SVG `xlink:href` are checked
without CSS colon escaping. Stylesheet `rel` tokens use ASCII case-insensitive
comparison and ASCII whitespace splitting, including multiple tokens and wrappers.

`serve.rb` handles directory indexes and returns the matching version’s 404 HTML
with **HTTP status 404**, including a trailing slash or nested path after an
existing HTML filename. It always selects WEBrick's static file handler, including
for extensions such as `.rhtml`; copied assets are never evaluated as templates.
GET and HEAD, literal `.rhtml` bytes, ordinary directory redirects, both mounts
and both versions are covered by the checker. A static `404.html` alone
does not configure a host. Any later hosting decision must configure base-path
serving, directory indexes, version-aware 404 routing, HTTPS, and verify deployed
search, keyboard/mobile navigation, copying and version switching. Content review,
hosting/publication, homepage/README links and browser acceptance remain parent
gates for #502.

Primary implementation references: [Jekyll 4.4.1 page Liquid guard](https://github.com/jekyll/jekyll/blob/v4.4.1/lib/jekyll/convertible.rb#L162),
[renderer/layout separation](https://github.com/jekyll/jekyll/blob/v4.4.1/lib/jekyll/renderer.rb),
[Just the Docs search](https://just-the-docs.com/docs/search/),
[code copying](https://just-the-docs.com/docs/ui-components/code/),
[GFM parser](https://github.com/kramdown/parser-gfm), and
[Sass converter](https://github.com/jekyll/jekyll-sass-converter).
