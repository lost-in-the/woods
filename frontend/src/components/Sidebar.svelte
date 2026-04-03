<script>
  import { TYPE_DOT_COLORS } from '../lib/theme.js';
  import TypeGroup from './TypeGroup.svelte';

  let {
    allNodes,
    activeNodeId,
    visibleNodeIds,
    filterText = $bindable(''),
    collapsedTypes,
    onSelectUnit,
    onToggleVisibility,
    onFocusUnit,
    onToggleCollapse,
    onShowAll,
    onHideAll,
  } = $props();

  const TYPE_SORT_ORDER = [
    'model', 'controller', 'job', 'service', 'mailer', 'concern',
  ];

  const filteredNodes = $derived.by(() => {
    if (!filterText) return allNodes;
    const q = filterText.toLowerCase();
    return allNodes.filter((n) => {
      const label = (n.data?.label || n.id || '').toLowerCase();
      return label.includes(q);
    });
  });

  const groupedByType = $derived.by(() => {
    const groups = {};
    for (const node of filteredNodes) {
      const t = node.data?.unitType || 'default';
      if (!groups[t]) groups[t] = [];
      groups[t].push(node);
    }
    return groups;
  });

  const sortedTypes = $derived.by(() => {
    const types = Object.keys(groupedByType);
    return types.sort((a, b) => {
      const ai = TYPE_SORT_ORDER.indexOf(a);
      const bi = TYPE_SORT_ORDER.indexOf(b);
      if (ai !== -1 && bi !== -1) return ai - bi;
      if (ai !== -1) return -1;
      if (bi !== -1) return 1;
      return a.localeCompare(b);
    });
  });

  const visibleCount = $derived(visibleNodeIds?.size ?? 0);
  const totalCount = $derived(allNodes?.length ?? 0);
</script>

<div class="sidebar-panel">
  <div class="sidebar-header">
    <span>Units</span>
    <span class="count">{visibleCount} / {totalCount}</span>
  </div>

  <input
    class="filter-input"
    type="text"
    placeholder="Filter units..."
    bind:value={filterText}
  />

  <div class="bulk-actions">
    <button onclick={() => onShowAll?.()}>Show All</button>
    <button onclick={() => onHideAll?.()}>Hide All</button>
  </div>

  <div class="sidebar-list">
    {#each sortedTypes as unitType (unitType)}
      <TypeGroup
        {unitType}
        units={groupedByType[unitType]}
        dotColor={TYPE_DOT_COLORS[unitType] || TYPE_DOT_COLORS.default}
        collapsed={collapsedTypes?.has(unitType) ?? false}
        {activeNodeId}
        {visibleNodeIds}
        {onToggleCollapse}
        {onSelectUnit}
        {onToggleVisibility}
        {onFocusUnit}
      />
    {/each}
  </div>
</div>
