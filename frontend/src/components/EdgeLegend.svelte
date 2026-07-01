<script>
  import { categoriesInEdges } from '../lib/edge-style.js';

  let { edges = [] } = $props();

  const categories = $derived(categoriesInEdges(edges));
</script>

{#if categories.length > 1}
  <div class="edge-legend">
    {#each categories as category}
      <div class="legend-item">
        <span class="legend-swatch" style="background: {category.color}"></span>
        <span class="legend-label">{category.label}</span>
      </div>
    {/each}
  </div>
{/if}

<style>
  .edge-legend {
    position: absolute;
    top: 12px;
    left: 12px;
    z-index: 5;
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 8px 10px;
    background: rgba(15, 23, 42, 0.85);
    border: 1px solid #334155;
    border-radius: 6px;
    font-size: 11px;
    color: #cbd5e1;
    pointer-events: none;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .legend-swatch {
    width: 14px;
    height: 3px;
    border-radius: 2px;
    flex-shrink: 0;
  }
</style>
