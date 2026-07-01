<script>
  import { TYPE_DOT_COLORS, getTypeDisplayName } from '../lib/theme.js';
  import SearchDropdown from './SearchDropdown.svelte';

  let {
    allNodes,
    centerNodeId,
    visibleNodeIds,
    hiddenNodeIds,
    recentNodes = [],
    onSelectUnit,
    onToggleVisibility,
    onClearAll,
  } = $props();

  let searchText = $state('');

  const visibleList = $derived.by(() => {
    return allNodes
      .filter((n) => visibleNodeIds?.has(n.id))
      .sort((a, b) => {
        // Center node first, then alphabetical
        if (a.id === centerNodeId) return -1;
        if (b.id === centerNodeId) return 1;
        return (a.data?.label || a.id).localeCompare(b.data?.label || b.id);
      });
  });

  const hiddenList = $derived.by(() => {
    return allNodes.filter((n) => !visibleNodeIds?.has(n.id));
  });

  const hiddenByType = $derived.by(() => {
    const groups = {};
    for (const node of hiddenList) {
      const t = node.data?.unitType || 'default';
      if (!groups[t]) groups[t] = [];
      groups[t].push(node);
    }
    return groups;
  });

  const hiddenTypes = $derived(
    Object.keys(hiddenByType).sort((a, b) => {
      const order = ['model', 'controller', 'job', 'service', 'mailer', 'concern'];
      const ai = order.indexOf(a);
      const bi = order.indexOf(b);
      if (ai !== -1 && bi !== -1) return ai - bi;
      if (ai !== -1) return -1;
      if (bi !== -1) return 1;
      return a.localeCompare(b);
    })
  );

  let hiddenExpanded = $state(false);
  let expandedHiddenTypes = $state(new Set());
  let recentExpanded = $state(true);

  const visibleCount = $derived(visibleNodeIds?.size ?? 0);
  const totalCount = $derived(allNodes?.length ?? 0);

  function toggleHiddenType(type) {
    const next = new Set(expandedHiddenTypes);
    if (next.has(type)) {
      next.delete(type);
    } else {
      next.add(type);
    }
    expandedHiddenTypes = next;
  }

  function handleSearchSelect(id) {
    searchText = '';
    onSelectUnit?.(id);
  }
</script>

<div class="sidebar-panel">
  <!-- Search -->
  <div class="search-container">
    <input
      class="search-input"
      type="text"
      placeholder="Search models..."
      bind:value={searchText}
    />
    <SearchDropdown
      query={searchText}
      {allNodes}
      onSelect={handleSearchSelect}
      onClose={() => { searchText = ''; }}
    />
  </div>

  <!-- Visible Section -->
  <div class="section">
    <div class="section-header sticky">
      <span>Visible</span>
      <span class="count">{visibleCount} / {totalCount}</span>
      {#if visibleCount > 1}
        <button class="clear-btn" onclick={onClearAll}>Clear All</button>
      {/if}
    </div>
    <div class="section-list">
      {#each visibleList as node (node.id)}
        <div
          class="node-item"
          class:center={node.id === centerNodeId}
          role="button"
          tabindex="0"
          onclick={() => onSelectUnit?.(node.id)}
          onkeydown={(e) => { if (e.key === 'Enter') onSelectUnit?.(node.id); }}
        >
          <span class="node-dot" style="background:{TYPE_DOT_COLORS[node.data?.unitType] || TYPE_DOT_COLORS.default};"></span>
          <span class="node-label">{node.data?.label || node.id}</span>
          <button
            class="eye-btn"
            title="Hide"
            onclick={(e) => { e.stopPropagation(); onToggleVisibility?.(node.id); }}
          >
            &#x1F441;
          </button>
        </div>
      {/each}
    </div>
  </div>

  <!-- Hidden Section -->
  <div class="section">
    <button class="section-header sticky clickable" onclick={() => { hiddenExpanded = !hiddenExpanded; }}>
      <span>Hidden</span>
      <span class="count">{hiddenList.length}</span>
      <span class="chevron">{hiddenExpanded ? '\u25BC' : '\u25B6'}</span>
    </button>
    {#if hiddenExpanded}
      <div class="section-list">
        {#each hiddenTypes as unitType (unitType)}
          <button class="type-header" onclick={() => toggleHiddenType(unitType)}>
            <span class="type-dot" style="background:{TYPE_DOT_COLORS[unitType] || TYPE_DOT_COLORS.default};"></span>
            <span>{getTypeDisplayName(unitType)}</span>
            <span class="count">{hiddenByType[unitType].length}</span>
            <span class="chevron">{expandedHiddenTypes.has(unitType) ? '\u25BC' : '\u25B6'}</span>
          </button>
          {#if expandedHiddenTypes.has(unitType)}
            {#each hiddenByType[unitType] as node (node.id)}
              <div
                class="node-item hidden-item"
                role="button"
                tabindex="0"
                onclick={() => onSelectUnit?.(node.id)}
                onkeydown={(e) => { if (e.key === 'Enter') onSelectUnit?.(node.id); }}
              >
                <span class="node-label">{node.data?.label || node.id}</span>
                <button
                  class="eye-btn off"
                  title="Show"
                  onclick={(e) => { e.stopPropagation(); onToggleVisibility?.(node.id); }}
                >
                  &#x2014;
                </button>
              </div>
            {/each}
          {/if}
        {/each}
      </div>
    {/if}
  </div>

  <!-- Recent Section -->
  <div class="section">
    <button class="section-header sticky clickable" onclick={() => { recentExpanded = !recentExpanded; }}>
      <span>Recent</span>
      <span class="count">{recentNodes.length}</span>
      <span class="chevron">{recentExpanded ? '\u25BC' : '\u25B6'}</span>
    </button>
    {#if recentExpanded && recentNodes.length > 0}
      <div class="section-list">
        {#each recentNodes as nodeId (nodeId)}
          {@const node = allNodes.find((n) => n.id === nodeId)}
          {#if node}
            <div
              class="node-item"
              role="button"
              tabindex="0"
              onclick={() => onSelectUnit?.(nodeId)}
              onkeydown={(e) => { if (e.key === 'Enter') onSelectUnit?.(nodeId); }}
            >
              <span class="node-dot" style="background:{TYPE_DOT_COLORS[node.data?.unitType] || TYPE_DOT_COLORS.default};"></span>
              <span class="node-label">{node.data?.label || node.id}</span>
            </div>
          {/if}
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .sidebar-panel {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }

  .search-container {
    position: relative;
    padding: 8px;
    border-bottom: 1px solid #334155;
  }

  .search-input {
    width: 100%;
    padding: 6px 10px;
    background: #0f172a;
    border: 1px solid #334155;
    border-radius: 6px;
    color: #e2e8f0;
    font-size: 12px;
    outline: none;
    box-sizing: border-box;
  }

  .search-input:focus {
    border-color: #475569;
  }

  .section {
    display: flex;
    flex-direction: column;
    min-height: 0;
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 10px;
    font-size: 11px;
    font-weight: 600;
    color: #94a3b8;
    border-bottom: 1px solid #334155;
    background: #1e293b;
  }

  .section-header.sticky {
    position: sticky;
    top: 0;
    z-index: 1;
  }

  .section-header.clickable {
    cursor: pointer;
    border: none;
    width: 100%;
    text-align: left;
  }

  .section-header.clickable:hover {
    background: #283548;
  }

  .section-list {
    overflow-y: auto;
    flex: 1;
  }

  .node-item {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    cursor: pointer;
    font-size: 11px;
    color: #e2e8f0;
  }

  .node-item:hover {
    background: #283548;
  }

  .node-item.center {
    color: #22c55e;
    font-weight: 600;
  }

  .node-item.hidden-item {
    padding-left: 28px;
    color: #64748b;
  }

  .node-dot {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .node-label {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .eye-btn {
    background: none;
    border: none;
    cursor: pointer;
    font-size: 11px;
    padding: 2px;
    opacity: 0;
    transition: opacity 0.1s;
    color: #94a3b8;
  }

  .node-item:hover .eye-btn {
    opacity: 1;
  }

  .eye-btn.off {
    color: #475569;
  }

  .clear-btn {
    margin-left: auto;
    background: none;
    border: 1px solid #334155;
    border-radius: 4px;
    color: #64748b;
    font-size: 9px;
    padding: 2px 6px;
    cursor: pointer;
  }

  .clear-btn:hover {
    border-color: #475569;
    color: #94a3b8;
  }

  .count {
    color: #475569;
    font-weight: 400;
  }

  .chevron {
    margin-left: auto;
    font-size: 9px;
    color: #475569;
  }

  .type-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    font-size: 10px;
    color: #64748b;
    cursor: pointer;
    background: none;
    border: none;
    border-top: 1px solid #1e293b;
    width: 100%;
    text-align: left;
  }

  .type-header:hover {
    background: #283548;
  }

  .type-dot {
    width: 6px;
    height: 6px;
    border-radius: 2px;
    flex-shrink: 0;
  }
</style>
