import { FC, useState, memo } from 'react'
import Link from 'next/link'
import Image from 'next/image'
import {
  Button,
  Form,
  Input,
  IconMinimize2,
  IconMaximize2,
  IconGitHub,
  IconTwitter,
} from '@supabase/ui'
import supabaseClient from '../client'
import { useTheme } from '../lib/ThemeProvider'

interface Props {}

const WaitlistPopover: FC<Props> = ({}) => {
  const { isDarkMode } = useTheme()
  const [isExpanded, setIsExpanded] = useState(true)
  const [isSuccess, setIsSuccess] = useState(false)
  const [error, setError] = useState<any>()

  const initialValues = { email: '' }

  const getGeneratedTweet = () => {
    return `Join me to experience Realtime by Supabase!%0A%0A${window.location.href}`
  }

  const onValidate = (values: any) => {
    const errors = {} as any
    const emailValidateRegex =
      /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*$/
    if (!emailValidateRegex.test(values.email)) errors.email = 'Please enter a valid email'
    return errors
  }

  const onSubmit = async (values: any, { setSubmitting, resetForm }: any) => {
    setIsSuccess(false)
    setError(undefined)
    setSubmitting(true)
    const { error } = await supabaseClient.from('waitlist').insert([{ email: values.email }])
    if (!error) {
      resetForm()
      setIsSuccess(true)
    } else {
      setError(error)
    }
    setSubmitting(false)
  }

  return (
    <div
      className={`bg-scale-200 border border-scale-500 dark:border-scale-300 p-6 rounded-md w-[400px] space-y-8 transition-all ${
        isExpanded ? 'max-h-[600px]' : 'max-h-[70px]'
      } duration-500 overflow-hidden shadow-2xl dark:shadow-lg`}
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center justify-center space-x-2">
          <Image
            src={isDarkMode ? `/img/supabase-dark.svg` : `/img/supabase-light.svg`}
            alt="supabase"
            height={20}
            width={100}
          />
          <div
            className={`transition relative -top-[1px] ${
              !isExpanded ? 'opacity-100' : 'opacity-0'
            } space-x-2 flex items-center`}
          >
            <p className={`transition-all text-scale-900 text-sm ${isExpanded ? '-ml-2' : 'ml-0'}`}>
              /
            </p>
            <p
              className={`transition-all text-scale-1200 text-sm ${isExpanded ? '-ml-2' : 'ml-0'}`}
            >
              Realtime
            </p>
          </div>
        </div>
        {isExpanded ? (
          <IconMinimize2
            className="transition-all text-scale-900 cursor-pointer hover:text-scale-1200 hover:scale-105"
            strokeWidth={2}
            size={16}
            onClick={() => setIsExpanded(false)}
          />
        ) : (
          <IconMaximize2
            className="transition-all text-scale-900 cursor-pointer hover:text-scale-1200 hover:scale-105"
            strokeWidth={2}
            size={16}
            onClick={() => setIsExpanded(true)}
          />
        )}
      </div>

      <div className="space-y-6">
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <h1 className="text-scale-1200 text-2xl">Realtime</h1>
          </div>
          <p className="text-sm text-scale-900">
            Realtime collaborative app to display broadcast, presence, and database listening over
            WebSockets
          </p>
        </div>
        <div>
          <a
            href="https://www.producthunt.com/posts/realtime-multiplayer-by-supabase?utm_source=badge-featured&utm_medium=badge&utm_souce=badge-realtime&#0045;multiplayer&#0045;by&#0045;supabase"
            rel="noreferrer"
            target="_blank"
          >
            <img
              src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=339695&theme=dark"
              alt="Realtime&#0032;Multiplayer&#0032;by&#0032;Supabase - Easily&#0032;build&#0032;real&#0045;time&#0032;apps&#0032;that&#0032;enables&#0032;user&#0032;collaboration | Product Hunt"
              style={{ width: '250px', height: '54px' }}
              width="250"
              height="54"
            />
          </a>
        </div>
        <div className="flex items-center gap-2">
          <Link href="https://github.com/supabase/realtime" passHref>
            <Button as="a" type="default" icon={<IconGitHub />}>
              View on GitHub
            </Button>
          </Link>
          <Link href={`https://twitter.com/intent/tweet?text=${getGeneratedTweet()}`} passHref>
            <Button as="a" type="alternative" icon={<IconTwitter />}>
              Invite on Twitter
            </Button>
          </Link>
        </div>
      </div>

      <Form validateOnBlur initialValues={initialValues} validate={onValidate} onSubmit={onSubmit}>
        {({ isSubmitting }: any) => {
          return (
            <>
              <Input
                id="email"
                name="email"
                size="small"
                placeholder="example@email.com"
                autoComplete="off"
                actions={[
                  <Button
                    className="mr-0.5"
                    key="submit"
                    htmlType="submit"
                    loading={isSubmitting}
                    disabled={isSubmitting}
                  >
                    Get early access
                  </Button>,
                ]}
              />
              {isSuccess && (
                <p className="text-sm text-green-1000 mt-2">
                  Thank you for submitting your interest!
                </p>
              )}
              {error?.message.includes('duplicate key') && (
                <p className="text-sm text-red-900 mt-2">
                  Email has already been registered for waitlist
                </p>
              )}
              {error && !error?.message.includes('duplicate key') && (
                <p className="text-sm text-red-900 mt-2">Unable to register email for waitlist</p>
              )}
            </>
          )
        }}
      </Form>
    </div>
  )
}

export default memo(WaitlistPopover)
