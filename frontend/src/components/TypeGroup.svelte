<script>
  import { getTypeDisplayName } from '../lib/theme.js';

  let {
    unitType,
    units,
    dotColor,
    collapsed,
    activeNodeId,
    visibleNodeIds,
    onToggleCollapse,
    onSelectUnit,
    onToggleVisibility,
    onFocusUnit,
  } = $props();

  const displayName = $derived(getTypeDisplayName(unitType));
</script>

<div class="type-group">
  <button
    class="type-group-header"
    aria-expanded={!collapsed}
    onclick={() => onToggleCollapse?.(unitType)}
  >
    <span class="type-group-chevron">{collapsed ? '\u25B6' : '\u25BC'}</span>
    <span class="type-group-dot" style="background:{dotColor};"></span>
    <span>{displayName}</span>
    <span class="type-group-count">{units.length}</span>
  </button>

  {#if !collapsed}
    {#each units as unit (unit.id)}
      <div
        class="unit-item"
        class:active={unit.id === activeNodeId}
        role="button"
        tabindex="0"
        onclick={(e) => {
          if (e.altKey) {
            onFocusUnit?.(unit.id);
          } else {
            onSelectUnit?.(unit.id);
          }
        }}
        onkeydown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onSelectUnit?.(unit.id);
          }
        }}
      >
        <span class="unit-item-name">{unit.data?.label || unit.id}</span>
        <button
          class="visibility-toggle"
          class:hidden={!visibleNodeIds?.has(unit.id)}
          aria-label={visibleNodeIds?.has(unit.id) ? `Hide ${unit.data?.label || unit.id}` : `Show ${unit.data?.label || unit.id}`}
          onclick={(e) => {
            e.stopPropagation();
            onToggleVisibility?.(unit.id);
          }}
        >
          {visibleNodeIds?.has(unit.id) ? '\u{1F441}' : '\u2014'}
        </button>
      </div>
    {/each}
  {/if}
</div>
