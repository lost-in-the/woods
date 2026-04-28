import type { WoodsNodeMember } from '@liam-hq/schema'
import { type FC, useState } from 'react'
import styles from './WoodsNode.module.css'

const MEMBER_CAP = 5

type Props = {
  members: WoodsNodeMember[]
}

export const WoodsNodeMemberList: FC<Props> = ({ members }) => {
  const [expanded, setExpanded] = useState(false)

  if (members.length === 0) {
    return null
  }

  const visibleMembers = expanded ? members : members.slice(0, MEMBER_CAP)
  const overflowCount = members.length - MEMBER_CAP

  return (
    <ul className={styles.memberList}>
      {visibleMembers.map((member) => (
        <li key={member.name} className={styles.memberItem}>
          {member.name}
        </li>
      ))}
      {overflowCount > 0 && (
        <li className={styles.memberToggle}>
          <button
            type="button"
            className={styles.memberToggleButton}
            onClick={() => setExpanded((prev) => !prev)}
          >
            {expanded ? 'Show less' : `+${overflowCount} more`}
          </button>
        </li>
      )}
    </ul>
  )
}
