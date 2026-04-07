import { clsx } from 'clsx'
import type { ComponentProps, Ref } from 'react'
import styles from './GridTable.module.css'

type GridTableRootProps = ComponentProps<'dl'>
export const GridTableRoot = ({
  className,
  ref,
  ...props
}: GridTableRootProps & {
  ref?: Ref<HTMLDListElement>
}) => <dl ref={ref} className={clsx(styles.root, className)} {...props} />

type GridTableHeaderProps = ComponentProps<'dt'>
export const GridTableHeader = ({
  className,
  ref,
  ...props
}: GridTableHeaderProps & {
  ref?: Ref<HTMLElement>
}) => (
  <div className={styles.dlItem}>
    <dt ref={ref} className={clsx(styles.dtHeader, className)} {...props} />
  </div>
)

type GridTableItemProps = ComponentProps<'div'>
export const GridTableItem = ({
  className,
  ref,
  ...props
}: GridTableItemProps & {
  ref?: Ref<HTMLDivElement>
}) => <div ref={ref} className={clsx(styles.dlItem, className)} {...props} />

type GridTableDtProps = ComponentProps<'dt'>
export const GridTableDt = ({
  className,
  ref,
  ...props
}: GridTableDtProps & {
  ref?: Ref<HTMLElement>
}) => <dt ref={ref} className={clsx(styles.dt, className)} {...props} />

type GridTableDdProps = ComponentProps<'dd'>
export const GridTableDd = ({
  className,
  ref,
  ...props
}: GridTableDdProps & {
  ref?: Ref<HTMLElement>
}) => <dd ref={ref} className={clsx(styles.dd, className)} {...props} />

type GridTableRowProps = ComponentProps<'dt'>
export const GridTableRow = ({
  className,
  ref,
  ...props
}: GridTableRowProps & {
  ref?: Ref<HTMLElement>
}) => (
  <dt ref={ref} className={clsx(styles.dt, styles.row, className)} {...props} />
)
