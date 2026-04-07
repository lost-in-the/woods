export type CommandPaletteInputMode = { type: 'default' } | { type: 'command' }

export type CommandPaletteSuggestion =
  | { type: 'table'; name: string }
  | { type: 'command'; name: string }
  | { type: 'woods'; name: string }
