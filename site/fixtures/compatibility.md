# Renderer compatibility fixture

This page is excluded from navigation and search. It tests the rendered candidate.

## Fake embeddings (CI / sandboxes / offline hosts)

[Consecutive hyphens](#fake-embeddings-ci--sandboxes--offline-hosts)

## Rails boot noise breaks MCP protocol

[Boot noise](#rails-boot-noise-breaks-mcp-protocol)

## Duplicate heading

First heading.

## Duplicate heading

[Second duplicate](#duplicate-heading-1)

<a name="named-html-anchor"></a>
<span id="explicit-html-anchor">Explicit HTML target</span>

[Named anchor](#named-html-anchor) and [explicit ID](#explicit-html-anchor).

[Reference style][guide]

[guide]: ../../docs/GETTING_STARTED.md?fixture=one&other=two

| Pipe table | Literal |
| --- | --- |
| Docker | `{{.Names}}` |
| Actions | `${{ github.run_id }}` |

<table id="raw-table">
  <thead><tr><th>Raw HTML table</th><th>Link</th></tr></thead>
  <tbody><tr><td>HTML</td><td><a href="../../docs/GETTING_STARTED.md?raw=1&amp;next=2">Getting started</a></td></tr></tbody>
</table>

```bash
docker ps --format '{{.Names}}'
```

```yaml
key: unblocked-sync-${{ env.UNBLOCKED_COLLECTION_ID }}-${{ github.run_id }}
```

```html
<a href="../../docs/GETTING_STARTED.md">This copy text must not be rewritten</a>
```

```html
<script src="https://example.com/theme.js"></script>
<img src="https://example.com/image.svg" alt="Fenced example">
<link rel="alternate StyleSheet" href="https://example.com/theme.css">
```

<code id="escaped-resource-copy">&lt;img src="https://example.com/image.svg" alt="Escaped example"&gt;</code>

```html
<svg><image href="https://example.com/image.svg" xlink:href="https://example.com/fallback.svg"></image></svg>
```

<code id="escaped-svg-resource-copy">&lt;svg&gt;&lt;image href="https://example.com/image.svg" xlink:href="https://example.com/fallback.svg"&gt;&lt;/image&gt;&lt;/svg&gt;</code>

<a id="absolute-included" href="https://github.com/lost-in-the/woods/blob/main/docs/GETTING_STARTED.md?view=1&amp;other=2">Absolute included guide</a>
<a id="root-included" href="/docs/GETTING_STARTED.md">Repository-root guide</a>
<a id="excluded-file" href="../../AGENTS.md?plain=1&amp;other=2#commands">Excluded file</a>
<a id="absolute-excluded" href="https://github.com/lost-in-the/woods/blob/main/AGENTS.md?plain=1#commands">Absolute excluded file</a>
<a id="excluded-directory" href="../../lib/?view=tree#source">Directory</a>
<a id="escaped-file" href="../../%41GENTS.md?escaped=%2F#commands">Escaped file</a>
<a id="external-link" href="https://example.com/docs/GETTING_STARTED.md?x=%2F#untouched">Other repository</a>

These source images are staged locally from this version's exact Git revision;
the rendered page and artifact checker exercise them without network access.

<img id="relative-asset" src="../../assets/woods-mark-black.svg?raw=1&amp;size=2" alt="Relative source asset">
<img id="absolute-asset" src="https://github.com/lost-in-the/woods/blob/main/assets/woods-mark-black.svg?raw=1" alt="Absolute source asset">

Formatting wrappers retain live resources, so these images also need rewriting
and full artifact validation.

<pre><img id="pre-asset" src="../../assets/woods-mark-black.svg?wrapped=pre" alt="Preformatted source asset"></pre>

<code><img id="code-asset" src="../../assets/woods-mark-black.svg?wrapped=code" alt="Inline source asset"></code>

SVG image and filter image attributes also embed resources. Both actual
attributes must stay distinct, version local and pinned, including inside live
formatting wrappers. SVG media fragments retain their own semantics.

<svg width="32" height="32" xmlns:xlink="http://www.w3.org/1999/xlink">
  <image id="svg-image-asset" width="32" height="32" href="../../assets/woods-mark-black.svg?fixture=svg-image-asset&amp;attribute=href#svgView(viewBox(0,0,120,120))" xlink:href="https://github.com/lost-in-the/woods/blob/main/assets/woods-mark-black.svg?fixture=svg-image-asset&amp;attribute=xlink:href#svgView(viewBox(0,0,120,120))"></image>
  <filter id="svg-image-filter"><feImage id="svg-filter-asset" href="https://raw.githubusercontent.com/lost-in-the/woods/main/assets/woods-mark-black.svg?fixture=svg-filter-asset&amp;attribute=href#svgView(viewBox(0,0,120,120))" xlink:href="../../assets/woods-mark-black.svg?fixture=svg-filter-asset&amp;attribute=xlink:href#svgView(viewBox(0,0,120,120))"></feImage></filter>
</svg>

<pre><svg width="32" height="32" xmlns:xlink="http://www.w3.org/1999/xlink"><image id="pre-svg-image-asset" width="32" height="32" href="../../assets/woods-mark-black.svg?fixture=pre-svg-image-asset&amp;attribute=href#svgView(viewBox(0,0,120,120))" xlink:href="../../assets/woods-mark-black.svg?fixture=pre-svg-image-asset&amp;attribute=xlink:href#svgView(viewBox(0,0,120,120))"></image><filter><feImage id="pre-svg-filter-asset" href="../../assets/woods-mark-black.svg?fixture=pre-svg-filter-asset&amp;attribute=href#svgView(viewBox(0,0,120,120))" xlink:href="../../assets/woods-mark-black.svg?fixture=pre-svg-filter-asset&amp;attribute=xlink:href#svgView(viewBox(0,0,120,120))"></feImage></filter></svg></pre>

<code><svg width="32" height="32" xmlns:xlink="http://www.w3.org/1999/xlink"><image id="code-svg-image-asset" width="32" height="32" href="../../assets/woods-mark-black.svg?fixture=code-svg-image-asset&amp;attribute=href#svgView(viewBox(0,0,120,120))" xlink:href="../../assets/woods-mark-black.svg?fixture=code-svg-image-asset&amp;attribute=xlink:href#svgView(viewBox(0,0,120,120))"></image><filter><feImage id="code-svg-filter-asset" href="../../assets/woods-mark-black.svg?fixture=code-svg-filter-asset&amp;attribute=href#svgView(viewBox(0,0,120,120))" xlink:href="../../assets/woods-mark-black.svg?fixture=code-svg-filter-asset&amp;attribute=xlink:href#svgView(viewBox(0,0,120,120))"></feImage></filter></svg></code>

The following intentionally broken Markdown is rendered separately by the checker;
each must fail, including same-repository absolute links and real rendered fragments.

<!-- negative-fixtures
[Missing relative file](../../docs/DOES_NOT_EXIST.md)
[Missing absolute file](https://github.com/lost-in-the/woods/blob/main/docs/DOES_NOT_EXIST.md)
[Missing included anchor](../../docs/GETTING_STARTED.md#does-not-exist-fixture)
[File used as directory](../../AGENTS.md/)
[Encoded file used as directory](../../AGENTS.md%2F)
![Encoded source file used as directory](../../assets/woods-mark-black.svg%2F)
[Missing named anchor](#missing-named-anchor)
![Missing source asset](../../assets/does-not-exist-fixture.svg)
negative-fixtures -->
