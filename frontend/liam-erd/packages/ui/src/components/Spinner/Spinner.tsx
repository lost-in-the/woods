import { type ComponentPropsWithoutRef, type FC, useId } from 'react'
import styles from './Spinner.module.css'

type SVGProps = ComponentPropsWithoutRef<'svg'>

const SVG: FC<SVGProps> = (props) => {
  const firstHalfId = useId()
  const secondHalfId = useId()

  return (
    <svg
      width="200"
      height="200"
      viewBox="-8 -8 216 216"
      color="white"
      fill="none"
      aria-label="loading"
      {...props}
    >
      <title>...Loading</title>
      <defs>
        <linearGradient id={secondHalfId}>
          <stop offset="0%" stopOpacity="0" stopColor="currentColor" />
          <stop offset="100%" stopOpacity="0.5" stopColor="currentColor" />
        </linearGradient>
        <linearGradient id={firstHalfId}>
          <stop offset="0%" stopOpacity="1" stopColor="currentColor" />
          <stop offset="100%" stopOpacity="0.5" stopColor="currentColor" />
        </linearGradient>
      </defs>

      <g
        strokeWidth="20"
        strokeLinejoin="round"
        shapeRendering="geometricPrecision"
      >
        <path
          stroke={`url(#${secondHalfId})`}
          d="M 4 100 A 96 96 0 0 1 196 100"
        />
        <path
          stroke={`url(#${firstHalfId})`}
          d="M 196 100 A 96 96 0 0 1 4 100"
        />

        <path
          stroke="currentColor"
          strokeLinecap="round"
          d="M 4 100 A 96 96 0 0 1 4 98"
        />
      </g>
    </svg>
  )
}

type Props = {
  size?: '12' | '14' | '16'
}

export const Spinner: FC<Props> = ({ size = '16' }) => {
  return (
    <SVG
      className={styles.svg}
      style={{
        width: size,
        height: size,
      }}
    />
  )
}
