// Type definitions for randomColor 0.5.2
// Project: https://github.com/davidmerfield/randomColor
// Definitions by: Mathias Feitzinger <https://github.com/feitzi>, Brady Liles <https://github.com/BradyLiles>
// Definitions: https://github.com/DefinitelyTyped/DefinitelyTyped

declare function randomColor(options?: RandomColorOptionsSingle): string
declare function randomColor(options?: RandomColorOptionsMultiple): string[]

interface RandomColorOptionsMultiple extends RandomColorOptionsSingle {
  count: number
}

export default function randomColor(options: any) {
  const colors = {
    tomato: {
      bg: 'var(--colors-tomato9)',
      hue: 'var(--colors-tomato7)',
    },
    // red: {
    //   bg: 'var(--colors-red9)',
    //   hue: 'var(--colors-red7)',
    // },
    crimson: {
      bg: 'var(--colors-crimson9)',
      hue: 'var(--colors-crimson7)',
    },
    pink: {
      bg: 'var(--colors-pink9)',
      hue: 'var(--colors-pink7)',
    },
    plum: {
      bg: 'var(--colors-plum9)',
      hue: 'var(--colors-plum7)',
    },
    // purple: {
    //   bg: 'var(--colors-purple9)',
    //   hue: 'var(--colors-purple7)',
    // },
    // violet: {
    //   bg: 'var(--colors-violet9)',
    //   hue: 'var(--colors-violet7)',
    // },
    indigo: {
      bg: 'var(--colors-indigo9)',
      hue: 'var(--colors-indigo7)',
    },
    blue: {
      bg: 'var(--colors-blue9)',
      hue: 'var(--colors-blue7)',
    },
    cyan: {
      bg: 'var(--colors-cyan9)',
      hue: 'var(--colors-cyan7)',
    },
    teal: {
      bg: 'var(--colors-teal9)',
      hue: 'var(--colors-teal7)',
    },
    green: {
      bg: 'var(--colors-green9)',
      hue: 'var(--colors-green7)',
    },
    // grass: {
    //   bg: 'var(--colors-grass9)',
    //   hue: 'var(--colors-grass7)',
    // },
    // brown: {
    //   bg: 'var(--colors-brown9)',
    //   hue: 'var(--colors-brown7)',
    // },
    orange: {
      bg: 'var(--colors-orange9)',
      hue: 'var(--colors-orange7)',
    },
  }

  const randomColor =
    Object.values(colors)[Math.floor(Math.random() * Object.values(colors).length)]

  return randomColor
}
