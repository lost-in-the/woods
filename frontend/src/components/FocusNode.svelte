<script>
  import { useSvelteFlow } from '@xyflow/svelte';

  let { nodeId } = $props(); // { id, t } object — t ensures re-trigger for same node

  const { setCenter, getNode } = useSvelteFlow();

  $effect(() => {
    const target = nodeId?.id;
    if (!target) return;
    const node = getNode(target);
    if (!node) return;
    const x = (node.position?.x ?? 0) + (node.measured?.width ?? 100) / 2;
    const y = (node.position?.y ?? 0) + (node.measured?.height ?? 40) / 2;
    setCenter(x, y, { zoom: 1, duration: 300 });
  });
</script>
