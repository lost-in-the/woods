import { pushToDataLayer } from './pushToDataLayer'
import type { CommonLogEvent } from './types'

type RepositionTable = CommonLogEvent & {
  tableId: string
  operationId: string
}

export const repositionTableLogEvent = (params: RepositionTable) => {
  pushToDataLayer({
    event: 'repositionTable',
    ...params,
  })
}
