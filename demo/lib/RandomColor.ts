export default function randomColor() {
  const colors = {
    tomato: {
      bg: 'var(--colors-tomato9)',
      hue: 'var(--colors-tomato7)',
    },
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
    orange: {
      bg: 'var(--colors-orange9)',
      hue: 'var(--colors-orange7)',
    },
    // red: {
    //   bg: 'var(--colors-red9)',
    //   hue: 'var(--colors-red7)',
    // },
    // grass: {
    //   bg: 'var(--colors-grass9)',
    //   hue: 'var(--colors-grass7)',
    // },
    // brown: {
    //   bg: 'var(--colors-brown9)',
    //   hue: 'var(--colors-brown7)',
    // },
    // purple: {
    //   bg: 'var(--colors-purple9)',
    //   hue: 'var(--colors-purple7)',
    // },
    // violet: {
    //   bg: 'var(--colors-violet9)',
    //   hue: 'var(--colors-violet7)',
    // },
  }

  return Object.values(colors)[Math.floor(Math.random() * Object.values(colors).length)]
}
