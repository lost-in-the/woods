import type { WoodsNodeType } from '@liam-hq/schema'

type NodeColorScheme = {
  header: string
  border: string
}

export const woodsNodeColors: Record<WoodsNodeType, NodeColorScheme> = {
  controller: { header: '#2563eb', border: '#60a5fa' },
  job: { header: '#d97706', border: '#fbbf24' },
  service: { header: '#9333ea', border: '#c084fc' },
  mailer: { header: '#db2777', border: '#f472b6' },
}
