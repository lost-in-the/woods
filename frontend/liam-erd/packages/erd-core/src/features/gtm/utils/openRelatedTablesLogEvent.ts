import { pushToDataLayer } from './pushToDataLayer'
import type { CommonLogEvent } from './types'

type OpenRelatedTablesLogEvent = CommonLogEvent & {
  tableId: string
}

export const openRelatedTablesLogEvent = (
  params: OpenRelatedTablesLogEvent,
) => {
  pushToDataLayer({
    event: 'openRelatedTables',
    ...params,
  })
}
