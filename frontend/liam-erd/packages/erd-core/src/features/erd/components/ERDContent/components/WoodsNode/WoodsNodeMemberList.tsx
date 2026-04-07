import type { WoodsNodeMember } from '@liam-hq/schema'
import type { FC } from 'react'
import styles from './WoodsNode.module.css'

type Props = {
  members: WoodsNodeMember[]
}

export const WoodsNodeMemberList: FC<Props> = ({ members }) => {
  if (members.length === 0) {
    return null
  }

  return (
    <ul className={styles.memberList}>
      {members.map((member) => (
        <li key={member.name} className={styles.memberItem}>
          {member.name}
        </li>
      ))}
    </ul>
  )
}
