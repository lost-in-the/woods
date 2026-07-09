import * as RadioGroupPrimitive from '@radix-ui/react-radio-group'
import clsx from 'clsx'
import type { ComponentProps, ElementRef, ReactNode, Ref } from 'react'
import { Check } from '../../icons'
import styles from './RadioGroup.module.css'

// Root
export const RadioGroup = ({
  className,
  ref,
  ...props
}: ComponentProps<typeof RadioGroupPrimitive.Root> & {
  ref?: Ref<ElementRef<typeof RadioGroupPrimitive.Root>>
}) => {
  return (
    <RadioGroupPrimitive.Root
      ref={ref}
      className={clsx(styles.root, className)}
      {...props}
    />
  )
}

RadioGroup.displayName = 'RadioGroup'

// Item
type RadioGroupItemProps = ComponentProps<typeof RadioGroupPrimitive.Item> & {
  label?: ReactNode
  ref?: Ref<ElementRef<typeof RadioGroupPrimitive.Item>>
}

export const RadioGroupItem = ({
  className,
  label,
  id,
  ref,
  ...props
}: RadioGroupItemProps) => {
  const itemId = id ?? props.value

  return (
    <div className={styles.radioWrapper}>
      <RadioGroupPrimitive.Item
        ref={ref}
        id={itemId}
        className={clsx(styles.item, className)}
        {...props}
      >
        {label && (
          <label htmlFor={itemId} className={styles.label}>
            {label}
          </label>
        )}
        <RadioGroupPrimitive.Indicator>
          <Check width={10} height={10} />
        </RadioGroupPrimitive.Indicator>
      </RadioGroupPrimitive.Item>
    </div>
  )
}

RadioGroupItem.displayName = 'RadioGroupItem'
