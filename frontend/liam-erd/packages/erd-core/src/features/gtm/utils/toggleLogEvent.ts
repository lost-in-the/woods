import { pushToDataLayer } from './pushToDataLayer'
import type { CommonLogEvent } from './types'

type ToggleLogEvent = CommonLogEvent & {
  element: string
  isShow: boolean
  tableId?: string
}

export const toggleLogEvent = (params: ToggleLogEvent) => {
  pushToDataLayer({
    event: 'toggle',
    ...params,
  })
}
