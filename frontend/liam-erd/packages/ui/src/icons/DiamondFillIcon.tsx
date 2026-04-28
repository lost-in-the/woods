import type { ComponentPropsWithoutRef, FC } from 'react'

type Props = ComponentPropsWithoutRef<'svg'>

export const DiamondFillIcon: FC<Props> = (props) => {
  return (
    <svg
      role="img"
      aria-label="DiamondFill"
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      {...props}
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M3.39608 13.3961C2.62505 12.625 2.62505 11.375 3.39608 10.6039L10.5034 3.49659C11.2744 2.72555 12.5245 2.72555 13.2956 3.49659L20.4029 10.6039C21.1739 11.375 21.1739 12.625 20.4029 13.3961L13.2956 20.5034C12.5245 21.2744 11.2744 21.2744 10.5034 20.5034L3.39608 13.3961Z"
        fill="currentColor"
      />
    </svg>
  )
}
