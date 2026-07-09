import { pushToDataLayer } from './pushToDataLayer'
import type { CommonLogEvent } from './types'

type ToolbarActionLogEvent = CommonLogEvent & {
  element: string
  zoomLevel?: string
  showMode?: string
}

export const toolbarActionLogEvent = (params: ToolbarActionLogEvent) => {
  pushToDataLayer({
    event: 'toolbarAction',
    ...params,
  })
}
