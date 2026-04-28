import { picklist } from 'valibot'

export const showModeSchema = picklist(['ALL_FIELDS', 'TABLE_NAME', 'KEY_ONLY'])
