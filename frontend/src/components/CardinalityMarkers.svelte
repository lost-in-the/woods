<script>
  // No props — this is a static SVG defs block
</script>

<svg style="position: absolute; width: 0; height: 0;">
  <defs>
    <!-- Single bar marker (one) -->
    <marker
      id="marker-bar"
      viewBox="0 0 10 14"
      refX="5"
      refY="7"
      markerWidth="10"
      markerHeight="14"
      orient="auto-start-reverse"
    >
      <line x1="5" y1="0" x2="5" y2="14" stroke="#475569" stroke-width="2" />
    </marker>

    <!-- Crow's foot marker (many) -->
    <marker
      id="marker-crow-foot"
      viewBox="0 0 16 14"
      refX="1"
      refY="7"
      markerWidth="16"
      markerHeight="14"
      orient="auto-start-reverse"
    >
      <line x1="14" y1="0" x2="1" y2="7" stroke="#475569" stroke-width="1.5" />
      <line x1="14" y1="14" x2="1" y2="7" stroke="#475569" stroke-width="1.5" />
      <line x1="14" y1="0" x2="14" y2="14" stroke="#475569" stroke-width="1.5" />
    </marker>
  </defs>
</svg>
