- Add the `js_module` unit type: one shallow unit per JavaScript or TypeScript
  file under `config.javascript_paths` (default `app/javascript/**/*.{js,ts,jsx,tsx,mjs}`
  and `app/assets/javascripts/**/*.js`; vendored, generated, minified and
  declaration files excluded). A linear token pass, with no JavaScript
  toolchain, records exports, imports resolved to local module paths,
  `via: :import` edges, the module kind (`stimulus_controller`, `alpine_data`,
  `stencil_component`, `custom_element`, `module`) and the names it is
  registered under (`application.register`, the `*_controller` filename
  convention and loader directories, `Alpine.data`, `Alpine.store`,
  `window.name = function`, Stencil `@Component({ tag })`,
  `customElements.define`). Source over 200 KB is omitted and flagged
  `source_omitted`.
