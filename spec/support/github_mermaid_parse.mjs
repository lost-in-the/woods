// Parses Mermaid texts with the Mermaid that GitHub renders (woods#826; the
// version woods-map#76 measured), for spec/diagrams/github_mermaid_spec.rb:
// reads [{name, text}] as JSON on stdin and writes
// {version, results: [{name, ok, detected, error}]} as JSON on stdout.
//
// argv: the vendored mermaid.min.js.gz and the vendored linkedom bundle,
// gzipped too and loaded from a data: URL, so no plain vendored JavaScript
// sits in the tree. The browser build of Mermaid sanitizes labels with
// DOMPurify while it parses, which needs a document, so it runs in a VM
// context whose global is a linkedom window. Parsing is Mermaid's own grammar
// check (`mermaid.parse`); it draws nothing. Node is a test-time tool only.
import { readFileSync } from "node:fs"
import { gunzipSync } from "node:zlib"
import { pathToFileURL } from "node:url"
import vm from "node:vm"

const source = gunzipSync(readFileSync(process.argv[2])).toString("utf8")
const dom = process.argv[3].endsWith(".gz")
  ? `data:text/javascript;base64,${gunzipSync(readFileSync(process.argv[3])).toString("base64")}`
  : pathToFileURL(process.argv[3]).href
const { parseHTML } = await import(dom)
const { window } = parseHTML("<!doctype html><html><head></head><body></body></html>")
const context = vm.createContext(window)
for (const name of ["console", "setTimeout", "clearTimeout", "queueMicrotask", "structuredClone", "URL", "TextEncoder", "TextDecoder"]) {
  context[name] = globalThis[name]
}
context.globalThis = context
context.window = context
context.self = context
vm.runInContext(source, context)

const mermaid = context.mermaid
mermaid.initialize({ startOnLoad: false, securityLevel: "strict" })
const version = (source.match(/\{version:"(\d+\.\d+\.\d+)"\}/) || [])[1] || null
const input = JSON.parse(readFileSync(0, "utf8"))
const results = []
for (const { name, text } of input) {
  try {
    const parsed = await mermaid.parse(text)
    results.push({ name, ok: true, detected: parsed.diagramType, error: null })
  } catch (error) {
    results.push({ name, ok: false, detected: null, error: String(error?.message || error).split("\n").slice(0, 4).join(" | ") })
  }
}
process.stdout.write(JSON.stringify({ version, results }))
