<script>
  import { TYPE_DOT_COLORS, getTypeDisplayName } from '../lib/theme.js';

  let { query, allNodes, onSelect, onClose } = $props();

  const results = $derived.by(() => {
    if (!query || query.length < 1) return [];
    const q = query.toLowerCase();
    const matches = allNodes
      .filter((n) => {
        const label = (n.data?.label || n.id || '').toLowerCase();
        return label.includes(q);
      })
      .slice(0, 50); // pre-filter limit

    // Group by type
    const groups = {};
    for (const node of matches) {
      const t = node.data?.unitType || 'default';
      if (!groups[t]) groups[t] = [];
      groups[t].push(node);
    }

    // Flatten with type headers, max 10 visible
    const flat = [];
    let count = 0;
    for (const [type, nodes] of Object.entries(groups)) {
      if (count >= 10) break;
      flat.push({ type: 'header', unitType: type, label: getTypeDisplayName(type) });
      for (const node of nodes) {
        if (count >= 10) break;
        const label = node.data?.label || node.id;
        const connections = (node.data?.dependencyCount || 0) + (node.data?.dependentCount || 0);
        flat.push({ type: 'result', id: node.id, label, unitType: node.data?.unitType, connections });
        count++;
      }
    }
    return flat;
  });

  const hasResults = $derived(results.some((r) => r.type === 'result'));

  function highlightMatch(text, query) {
    if (!query) return text;
    const idx = text.toLowerCase().indexOf(query.toLowerCase());
    if (idx === -1) return text;
    return text.slice(0, idx) + '<mark>' + text.slice(idx, idx + query.length) + '</mark>' + text.slice(idx + query.length);
  }

  function handleSelect(id) {
    onSelect?.(id);
    onClose?.();
  }

  function handleKeydown(e) {
    if (e.key === 'Escape') {
      e.preventDefault();
      onClose?.();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if query && query.length > 0}
  <!-- Backdrop to catch clicks outside -->
  <div class="search-backdrop" onclick={onClose}></div>

  <div class="search-dropdown">
    {#if !hasResults}
      <div class="no-results">No matches for "{query}"</div>
    {:else}
      {#each results as item}
        {#if item.type === 'header'}
          <div class="result-header">
            <span class="result-dot" style="background:{TYPE_DOT_COLORS[item.unitType] || TYPE_DOT_COLORS.default};"></span>
            {item.label}
          </div>
        {:else}
          <button class="result-item" onclick={() => handleSelect(item.id)}>
            <span class="result-name">{@html highlightMatch(item.label, query)}</span>
            {#if item.connections > 0}
              <span class="result-connections">{item.connections}</span>
            {/if}
          </button>
        {/if}
      {/each}
    {/if}
  </div>
{/if}

<style>
  .search-backdrop {
    position: fixed;
    inset: 0;
    z-index: 99;
  }

  .search-dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 0 0 6px 6px;
    max-height: 320px;
    overflow-y: auto;
    z-index: 100;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  }

  .result-header {
    padding: 6px 10px 4px;
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #64748b;
    display: flex;
    align-items: center;
    gap: 6px;
    border-top: 1px solid #334155;
  }

  .result-header:first-child {
    border-top: none;
  }

  .result-dot {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .result-item {
    display: flex;
    align-items: center;
    width: 100%;
    padding: 6px 10px 6px 22px;
    background: none;
    border: none;
    color: #e2e8f0;
    font-size: 12px;
    cursor: pointer;
    text-align: left;
    gap: 8px;
  }

  .result-item:hover {
    background: #334155;
  }

  .result-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  :global(.result-name mark) {
    background: rgba(34, 197, 94, 0.3);
    color: #22c55e;
    border-radius: 2px;
    padding: 0 1px;
  }

  .result-connections {
    font-size: 10px;
    color: #64748b;
    flex-shrink: 0;
  }

  .no-results {
    padding: 12px;
    color: #64748b;
    font-size: 12px;
    text-align: center;
  }
</style>
