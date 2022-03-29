const ui = require('@supabase/ui/dist/config/ui.config.js')

const blueGray = {
  50: '#F8FAFC',
  100: '#F1F5F9',
  200: '#E2E8F0',
  300: '#CBD5E1',
  400: '#94A3B8',
  500: '#64748B',
  600: '#475569',
  700: '#334155',
  800: '#1E293B',
  900: '#0F172A',
}

const coolGray = {
  50: '#F9FAFB',
  100: '#F3F4F6',
  200: '#E5E7EB',
  300: '#D1D5DB',
  400: '#9CA3AF',
  500: '#6B7280',
  600: '#4B5563',
  700: '#374151',
  800: '#1F2937',
  900: '#111827',
}

module.exports = ui({
  darkMode: 'class', // or 'media' or 'class'
  content: [
    // purge styles from app
    './pages/**/*.{js,ts,jsx,tsx}',
    './components/**/*.{js,ts,jsx,tsx}',
    './internals/**/*.{js,ts,jsx,tsx}',
    './lib/**/*.{js,ts,jsx,tsx}',
    './lib/**/**/*.{js,ts,jsx,tsx}',
    // purge styles from supabase ui theme
    './node_modules/@supabase/ui/dist/config/default-theme.js',
  ],
  theme: {
    fontFamily: {
      sans: ['circular', 'Helvetica Neue', 'Helvetica', 'Arial', 'sans-serif'],
      mono: ['source code pro', 'Menlo', 'monospace'],
    },
    borderColor: (theme) => ({
      ...theme('colors'),
      DEFAULT: 'var(--colors-scale5)',
      dark: 'var(--colors-scale4)',
    }),
    divideColor: (theme) => ({
      ...theme('colors'),
      DEFAULT: 'var(--colors-scale3)',
      dark: 'var(--colors-scale2)',
    }),
    extend: {
      typography: ({ theme }) => ({
        // Removal of backticks in code blocks for tailwind v3.0
        // https://github.com/tailwindlabs/tailwindcss-typography/issues/135
        DEFAULT: {
          css: {
            'code::before': {
              content: '""',
            },
            'code::after': {
              content: '""',
            },
          },
        },
        docs: {
          css: {
            '--tw-prose-body': theme('colors.scale[1100]'),
            '--tw-prose-headings': theme('colors.scale[1200]'),
            '--tw-prose-lead': theme('colors.scale[1100]'),
            '--tw-prose-links': theme('colors.brand[900]'),
            '--tw-prose-bold': theme('colors.scale[1100]'),
            '--tw-prose-counters': theme('colors.scale[1100]'),
            '--tw-prose-bullets': theme('colors.scale[900]'),
            '--tw-prose-hr': theme('colors.scale[500]'),
            '--tw-prose-quotes': theme('colors.scale[1100]'),
            '--tw-prose-quote-borders': theme('colors.scale[500]'),
            '--tw-prose-captions': theme('colors.scale[700]'),
            '--tw-prose-code': theme('colors.scale[1200]'),
            '--tw-prose-pre-code': theme('colors.scale[900]'),
            '--tw-prose-pre-bg': theme('colors.scale[400]'),
            '--tw-prose-th-borders': theme('colors.scale[500]'),
            '--tw-prose-td-borders': theme('colors.scale[200]'),
            '--tw-prose-invert-body': theme('colors.scale[200]'),
            '--tw-prose-invert-headings': theme('colors.white'),
            '--tw-prose-invert-lead': theme('colors.scale[500]'),
            '--tw-prose-invert-links': theme('colors.white'),
            '--tw-prose-invert-bold': theme('colors.white'),
            '--tw-prose-invert-counters': theme('colors.scale[400]'),
            '--tw-prose-invert-bullets': theme('colors.scale[600]'),
            '--tw-prose-invert-hr': theme('colors.scale[700]'),
            '--tw-prose-invert-quotes': theme('colors.scale[100]'),
            '--tw-prose-invert-quote-borders': theme('colors.scale[700]'),
            '--tw-prose-invert-captions': theme('colors.scale[400]'),
            'h1, h2, h3, h4, h5': {
              fontWeight: '400',
            },
          },
        },
      }),
      colors: {
        blueGray: { ...blueGray },
        coolGray: { ...coolGray },

        /*  typography */
        'typography-body': {
          light: 'var(--colors-scale11)',
          dark: 'var(--colors-scale11)',
        },
        'typography-body-secondary': {
          light: 'var(--colors-scale10)',
          dark: 'var(--colors-scale10)',
        },
        'typography-body-strong': {
          light: 'var(--colors-scale12)',
          dark: 'var(--colors-scale12)',
        },
        'typography-body-faded': {
          light: 'var(--colors-scale9)',
          dark: 'var(--colors-scale9)',
        },

        /* borders */
        'border-secondary': {
          light: 'var(--colors-scale7)',
          dark: 'var(--colors-scale7)',
        },
        'border-secondary-hover': {
          light: 'var(--colors-scale9)',
          dark: 'var(--colors-scale9)',
        },

        /*  app backgrounds */
        'bg-primary': {
          light: 'var(--colors-scale2)',
          dark: 'var(--colors-scale2)',
        },
        'bg-secondary': {
          light: 'var(--colors-scale2)',
          dark: 'var(--colors-scale2)',
        },
        'bg-alt': {
          light: 'var(--colors-scale2)',
          dark: 'var(--colors-scale2)',
        },
      },
      animation: {
        gradient: 'gradient 60s ease infinite',
      },
      keyframes: {
        gradient: {
          '0%': {
            'background-position': '0% 50%',
          },
          '50%': {
            'background-position': '100% 50%',
          },
          '100%': {
            'background-position': '0% 50%',
          },
        },
      },
    },
  },
  variants: {
    extend: {},
  },
  plugins: [require('@tailwindcss/typography')],
})
