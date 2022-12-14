import { IconSun, IconMoon } from '@supabase/ui'
import { useEffect } from 'react'
import { useTheme } from '../lib/ThemeProvider'

function DarkModeToggle() {
  const { isDarkMode, toggleTheme } = useTheme()

  const toggleDarkMode = () => {
    localStorage.setItem('supabaseDarkMode', (!isDarkMode).toString())
    toggleTheme()

    const key = localStorage.getItem('supabaseDarkMode')
    document.documentElement.className = key === 'true' ? 'dark' : ''
  }

  useEffect(() => {
    const key = localStorage.getItem('supabaseDarkMode')
    if (key && key == 'false') {
      document.documentElement.className = ''
    }
  }, [])

  return (
    <div className="flex items-center">
      <button
        type="button"
        aria-pressed="false"
        className={`
                relative inline-flex flex-shrink-0 h-6 w-11 border-2 border-transparent rounded-full cursor-pointer 
                transition-colors ease-in-out duration-200 focus:outline-none ${
                  isDarkMode
                    ? 'bg-scale-500 hover:bg-scale-700'
                    : 'bg-scale-900 hover:bg-scale-1100'
                }
              `}
        onClick={() => toggleDarkMode()}
      >
        <span className="sr-only">Toggle Themes</span>
        <span
          aria-hidden="true"
          className={`
          relative
                  ${
                    isDarkMode ? 'translate-x-5' : 'translate-x-0'
                  } inline-block h-5 w-5 rounded-full
                  bg-white dark:bg-scale-300 shadow-lg transform ring-0 transition ease-in-out duration-200
                `}
        >
          <IconSun
            className={
              'absolute top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 text-scale-900 ' +
              (!isDarkMode ? 'opacity-100' : 'opacity-0')
            }
            strokeWidth={2}
            size={12}
          />
          <IconMoon
            className={
              'absolute top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 text-scale-900 ' +
              (isDarkMode ? 'opacity-100' : 'opacity-0')
            }
            strokeWidth={2}
            size={14}
          />
        </span>
      </button>
    </div>
  )
}

export default DarkModeToggle
