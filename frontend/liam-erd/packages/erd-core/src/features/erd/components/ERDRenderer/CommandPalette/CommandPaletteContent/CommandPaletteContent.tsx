import { Button } from '@liam-hq/ui'
import { DialogClose } from '@radix-ui/react-dialog'
import { Command, defaultFilter } from 'cmdk'
import { type FC, useCallback, useMemo, useState } from 'react'
import { EntryPointOptions, TableOptions, WoodsNodeOptions } from '../CommandPaletteOptions'
import { TablePreview } from '../CommandPalettePreview/TablePreview'
import { CommandPaletteFooter } from '../CommandPaletteFooter/CommandPaletteFooter'
import { CommandPaletteSearchInput } from '../CommandPaletteSearchInput'
import { useCommandPaletteOrThrow } from '../CommandPaletteProvider'
import type { CommandPaletteInputMode } from '../types'
import { textToSuggestion } from '../utils'
import styles from './CommandPaletteContent.module.css'

const commandPaletteFilter: typeof defaultFilter = (value, ...rest) => {
  const suggestion = textToSuggestion(value)

  // if the value is inappropriate for suggestion, it returns 0 and the options is hidden
  // https://github.com/pacocoursey/cmdk/blob/d6fde235386414196bf80d9b9fa91e2cf89a72ea/cmdk/src/index.tsx#L91-L95
  if (!suggestion) return 0

  return defaultFilter(suggestion.name, ...rest)
}

export const CommandPaletteContent: FC = () => {
  // TODO: switch inputMode with `setInputMode`
  const [inputMode, setInputMode] = useState<CommandPaletteInputMode>({
    type: 'default',
  })

  const [suggestionText, setSuggestionText] = useState('')
  const suggestion = useMemo(
    () => textToSuggestion(suggestionText),
    [suggestionText],
  )

  const { setOpen } = useCommandPaletteOrThrow()

  const handleFocusNode = useCallback(
    (nodeId: string) => {
      window.dispatchEvent(
        new CustomEvent('erd:focus-node', { detail: { nodeId } }),
      )
      setOpen(false)
    },
    [setOpen],
  )

  const handleToggleFocusNode = useCallback(
    (nodeId: string) => {
      window.dispatchEvent(
        new CustomEvent('erd:toggle-focus-node', { detail: { nodeId } }),
      )
      setOpen(false)
    },
    [setOpen],
  )

  return (
    <Command
      value={suggestionText}
      onValueChange={(v) => setSuggestionText(v)}
      filter={commandPaletteFilter}
    >
      <div className={styles.searchContainer}>
        <CommandPaletteSearchInput
          mode={inputMode}
          setMode={setInputMode}
          onBlur={(event) => event.target.focus()}
        />
        <DialogClose asChild>
          <Button
            size="xs"
            variant="outline-secondary"
            className={styles.escButton}
          >
            ESC
          </Button>
        </DialogClose>
      </div>
      <div className={styles.main}>
        <Command.List>
          <Command.Empty>No results found.</Command.Empty>
          {inputMode.type === 'default' && (
            <>
              <EntryPointOptions />
              <TableOptions suggestion={suggestion} />
              <WoodsNodeOptions
                onSelectNode={handleFocusNode}
                onToggleNode={handleToggleFocusNode}
              />
            </>
          )}
          {
            (inputMode.type === 'default' || inputMode.type === 'command') &&
              null
            // TODO(command options): uncomment the following line to release command options
            // <CommandPaletteCommandOptions />
          }
        </Command.List>
        <div
          className={styles.previewContainer}
          data-testid="CommandPalettePreview"
        >
          {suggestion?.type === 'table' && (
            <TablePreview tableName={suggestion.name} />
          )}
          {
            suggestion?.type === 'command' && null
            // TODO(command options): display a preview component for command options, as like:
            // <CommandPreview commandName={suggestion.name} />
          }
        </div>
      </div>
      <CommandPaletteFooter />
    </Command>
  )
}
