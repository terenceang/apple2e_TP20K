// ============================================================================
//  AppleGlyph.tsx -- the two apple keys
//
//  Open-Apple is an outline apple and Solid-Apple is a filled one, and they are
//  the most recognisable thing about a //e keyboard. They were the 1F34F and
//  1F34E emoji, which is a bad idea: whether they appear at all depends on
//  whether the machine has an emoji font installed, and a //e with two blank
//  squares where its apple keys should be is worse than one drawn as SVG.
//
//  The shapes are deliberately a plain apple silhouette -- a body with a notch
//  at the top, a bite on the right and a leaf -- rather than a copy of
//  Apple's logo.
// ============================================================================

/** One shape, used as an outline for Open-Apple and a fill for Solid-Apple. */
export function AppleGlyph({ solid = false, className }: { solid?: boolean; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width="1em"
      height="1em"
      className={className}
      aria-hidden="true"
      focusable="false"
      fill={solid ? 'currentColor' : 'none'}
      stroke={solid ? 'none' : 'currentColor'}
      strokeWidth={solid ? 0 : 1.5}
      strokeLinejoin="round"
    >
      {/* body: notched at the top, bitten out of the right */}
      <path
        d="M12.4 6.4c-1.1-.9-2.3-1.3-3.6-1.3C5.4 5.1 3.2 7.5 3.2 11.4c0 2.7 1.3 5.5 2.6 7.4.8 1.1 1.8 2.1 3.1 2.1
           1.2 0 1.6-.7 2.8-.7s1.6.7 2.8.7c1.3 0 2.3-1 3.1-2.1.4-.6.8-1.3 1.1-2
           -2.5-1-3.5-3.5-3.5-5.4 0-1.7 1-3 2.5-3.6-.4-.3-.9-.4-1.4-.4-1.2 0-2.6.6-3.9 1.4z"
      />
      {/* leaf */}
      <path d="M15.6 4.3c-.1-1.2.7-2.4 1.9-3 .1 1.3-.4 2.5-1.2 3.3-.7.6-1.6 1-2.5 1 .1-1.2.8-2.2 1.8-2.6z" />
    </svg>
  )
}
