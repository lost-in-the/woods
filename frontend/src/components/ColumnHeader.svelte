<script>
  let { label, parentName, relationshipType, count } = $props();

  const displayLabel = $derived(
    parentName
      ? `${parentName} \u2192 ${relationshipType || 'dependencies'}`
      : label || 'Center'
  );
</script>

<div class="column-header">
  <span class="column-label">{displayLabel}</span>
  {#if count != null}
    <span class="column-count">({count})</span>
  {/if}
</div>

<style>
  .column-header {
    padding: 6px 8px;
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: #64748b;
    display: flex;
    align-items: center;
    gap: 4px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .column-count {
    color: #475569;
  }
</style>
