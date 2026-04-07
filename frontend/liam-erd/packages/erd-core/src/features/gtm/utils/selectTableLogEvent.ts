import { pushToDataLayer } from './pushToDataLayer'
import type { CommonLogEvent } from './types'

type SelectTable = CommonLogEvent & {
  ref: 'leftPane' | 'mainArea'
  tableId: string
}

export const selectTableLogEvent = ({
  ref,
  tableId,
  platform,
  ver,
  gitHash,
  appEnv,
}: SelectTable) => {
  pushToDataLayer({
    event: 'selectTable',
    ref,
    tableId,
    platform,
    ver,
    gitHash,
    appEnv,
  })
}
