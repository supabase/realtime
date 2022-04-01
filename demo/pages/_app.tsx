import '../styles/globals.css'
import type { AppProps } from 'next/app'
import Head from 'next/head'
import { ThemeProvider } from '../lib/ThemeProvider'

function MyApp({ Component, pageProps }: AppProps) {
  return (
    <>
      <Head>
        <title>Multiplayer.dev</title>
        <link rel="icon" href="/favicon.ico" />
        <meta name="description" content="Presence and ephemeral state, by Supabase" />

        <meta
          key="ogimage"
          property="og:image"
          content="https://mfrkmguhoejspftfvgdz.supabase.co/storage/v1/object/public/og-assets/supabase-multiplayer-og.png"
        />
        <meta property="og:site_name" key="ogsitename" content="multiplayer.dev" />
        <meta property="og:title" key="ogtitle" content="Realtime | Supabase" />
        <meta property="og:description" key="ogdesc" content="Presence and ephemeral state" />
      </Head>
      <ThemeProvider>
        <Component {...pageProps} />
      </ThemeProvider>
    </>
  )
}

export default MyApp
