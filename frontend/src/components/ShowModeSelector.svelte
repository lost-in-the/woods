<script>
  let { mode, onModeChange } = $props();

  const modes = [
    { value: 'all_fields', label: 'All Fields' },
    { value: 'key_only', label: 'Key Only' },
    { value: 'table_name', label: 'Table Name' },
  ];
</script>

<div class="show-mode-selector">
  {#each modes as m}
    <button
      class="mode-btn"
      class:active={mode === m.value}
      onclick={() => onModeChange(m.value)}
    >
      {m.label}
    </button>
  {/each}
</div>

<style>
  .show-mode-selector {
    display: flex;
    gap: 1px;
    background: #334155;
    border-radius: 6px;
    overflow: hidden;
    font-size: 11px;
  }
  .mode-btn {
    padding: 4px 10px;
    background: #1e293b;
    color: #94a3b8;
    border: none;
    cursor: pointer;
    white-space: nowrap;
  }
  .mode-btn:hover {
    background: #334155;
    color: #e2e8f0;
  }
  .mode-btn.active {
    background: #475569;
    color: #e2e8f0;
    font-weight: 600;
  }
</style>
