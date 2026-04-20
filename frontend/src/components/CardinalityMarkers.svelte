<script>
  // Cardinality marker definitions for ERD-style edges.
  // Rendered as an inline hidden SVG so defs exist before edges render —
  // eliminates timing race with DOM injection approach.
</script>

<svg class="cardinality-defs" width="0" height="0">
  <defs>
    <!-- Bar marker: single vertical bar ("one" side) -->
    <marker
      id="marker-bar"
      viewBox="0 0 10 14"
      refX="5"
      refY="7"
      markerWidth="10"
      markerHeight="14"
      orient="auto-start-reverse"
    >
      <line x1="5" y1="0" x2="5" y2="14" stroke="#94a3b8" stroke-width="2" />
    </marker>

    <!-- Crow's foot marker: three-pronged fork ("many" side) -->
    <marker
      id="marker-crow-foot"
      viewBox="0 0 16 14"
      refX="1"
      refY="7"
      markerWidth="16"
      markerHeight="14"
      orient="auto-start-reverse"
    >
      <line x1="14" y1="0" x2="1" y2="7" stroke="#94a3b8" stroke-width="1.5" />
      <line x1="14" y1="14" x2="1" y2="7" stroke="#94a3b8" stroke-width="1.5" />
      <line x1="14" y1="0" x2="14" y2="14" stroke="#94a3b8" stroke-width="1.5" />
    </marker>
  </defs>
</svg>

<style>
  .cardinality-defs {
    position: absolute;
    width: 0;
    height: 0;
    overflow: hidden;
    pointer-events: none;
  }
</style>
