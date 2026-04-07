import type { NodeProps } from '@xyflow/react'
import clsx from 'clsx'
import type { FC } from 'react'
import type { WoodsNodeType } from '@/features/erd/types'
import styles from './WoodsNode.module.css'
import { WoodsNodeHeader } from './WoodsNodeHeader'
import { WoodsNodeMemberList } from './WoodsNodeMemberList'
import { woodsNodeColors } from './woodsNodeColors'

type Props = NodeProps<WoodsNodeType>

export const WoodsNode: FC<Props> = ({ data }) => {
  const colors = woodsNodeColors[data.type]

  return (
    <div
      className={clsx(
        styles.wrapper,
        data.isHoverHighlighted && styles.wrapperHoverHighlighted,
        data.isHighlighted && styles.wrapperHighlighted,
        data.isActiveHighlighted && styles.wrapperActive,
      )}
      style={{
        '--woods-border-color': colors.border,
      } as React.CSSProperties}
    >
      <WoodsNodeHeader name={data.name} type={data.type} meta={data.meta} />
      <WoodsNodeMemberList members={data.members} />
    </div>
  )
}
