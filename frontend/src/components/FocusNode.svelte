<script>
  import { useSvelteFlow } from '@xyflow/svelte';

  let { nodeId } = $props();

  const { setCenter, getNode } = useSvelteFlow();

  $effect(() => {
    if (!nodeId) return;
    const node = getNode(nodeId);
    if (!node) return;
    const x = (node.position?.x ?? 0) + (node.measured?.width ?? 100) / 2;
    const y = (node.position?.y ?? 0) + (node.measured?.height ?? 40) / 2;
    setCenter(x, y, { zoom: 1, duration: 300 });
  });
</script>
