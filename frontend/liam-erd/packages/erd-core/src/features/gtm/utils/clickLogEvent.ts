import { pushToDataLayer } from './pushToDataLayer'
import type { CommonLogEvent } from './types'

type ClickLogEvent = CommonLogEvent & {
  element: string
}

export const clickLogEvent = (params: ClickLogEvent) => {
  pushToDataLayer({
    event: 'click',
    ...params,
  })
}
