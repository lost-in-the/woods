type WindowWithDataLayer = Window & {
  dataLayer: Record<string, unknown>[]
}

declare const window: WindowWithDataLayer

export const pushToDataLayer = (obj: Record<string, unknown>) => {
  window.dataLayer = window.dataLayer || []
  window.dataLayer.push(obj)
}
