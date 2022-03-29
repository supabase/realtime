import { FC, useState } from 'react'
import Link from 'next/link'
import Image from 'next/image'
import { Button, Form, Input, IconMinimize2, IconMaximize2 } from '@supabase/ui'
import { supabaseClient } from '../client/SupabaseClient'

interface Props {}

const WaitlistPopover: FC<Props> = ({}) => {
  const [isExpanded, setIsExpanded] = useState(true)
  const [isSuccess, setIsSuccess] = useState(false)
  const [error, setError] = useState<any>()

  const initialValues = { email: '' }

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
    const { error } = await supabaseClient
      .from('waitlist')
      .insert([{ email: values.email }], { returning: 'minimal' })
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
      className={`bg-scale-400 border border-scale-600 p-6 rounded-md w-[400px] space-y-8 transition-all ${
        isExpanded ? 'max-h-[600px]' : 'max-h-[70px]'
      } duration-500 overflow-hidden shadow-lg`}
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center justify-center space-x-2">
          <Image src="/img/supabase-dark.svg" alt="supabase" height={20} width={100} />
          <div
            className={`transition relative -top-[1px] ${
              !isExpanded ? 'opacity-100' : 'opacity-0'
            } space-x-2 flex items-center`}
          >
            <p className="text-scale-1200 text-sm">•</p>
            <p className="text-scale-1200 text-sm">Multiplayer</p>
          </div>
        </div>
        {isExpanded ? (
          <IconMinimize2
            className="text-scale-1200 cursor-pointer"
            strokeWidth={2}
            size={20}
            onClick={() => setIsExpanded(false)}
          />
        ) : (
          <IconMaximize2
            className="text-scale-1200 cursor-pointer"
            strokeWidth={2}
            size={20}
            onClick={() => setIsExpanded(true)}
          />
        )}
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <h1 className="text-scale-1200 text-3xl">Multiplayer</h1>
          <Link href="https://github.com/supabase/multiplayer">
            <a target="_blank">
              <svg
                className="h-6 w-6 text-scale-1200 cursor-pointer"
                fill="currentColor"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <path
                  fillRule="evenodd"
                  d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"
                  clipRule="evenodd"
                ></path>
              </svg>
            </a>
          </Link>
        </div>
        <p className="text-sm text-scale-1100">
          Build realtime collaborative applications quickly through a simple set of APIs -
          Multiplayer provides Pub/Sub, presence and ephemeral state
        </p>
      </div>

      <Form validateOnBlur initialValues={initialValues} validate={onValidate} onSubmit={onSubmit}>
        {({ isSubmitting }: any) => {
          return (
            <>
              <Input
                id="email"
                name="email"
                placeholder="example@email.com"
                actions={[
                  <div key="email-submit" className="mr-1">
                    <Button
                      key="submit"
                      htmlType="submit"
                      loading={isSubmitting}
                      disabled={isSubmitting}
                    >
                      Get early access
                    </Button>
                  </div>,
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

export default WaitlistPopover
