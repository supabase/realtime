import { FC } from 'react'
import { Button, Form, IconSend, Input } from '@supabase/ui'
import { Message } from '../types/main.type'
import { supabaseClient } from '../client/SupabaseClient'

interface Props {
  messages: Message[]
  roomId: string
  userId: string
}

const Chatbox: FC<Props> = ({ messages, roomId, userId }) => {
  const initialValues = { message: '' }

  const onSubmit = async (values: any, { setSubmitting, resetForm }: any) => {
    if (values.message.length === 0) return

    setSubmitting(true)

    const message = {
      message: values.message,
      room_id: roomId,
      user_id: userId,
    }

    const { error } = await supabaseClient.from('messages').insert([message])

    if (!error) {
      resetForm()
    }

    setSubmitting(false)
  }

  return (
    <div className="flex flex-col break-all">
      <div
        className="space-y-1 rounded py-2 px-3 w-[400px]"
        style={{ backgroundColor: 'rgba(0, 207, 144, 0.05)' }}
      >
        {messages.length === 0 && (
          <p className="text-scale-1200 text-sm opacity-75">Start chatting 🥳</p>
        )}
        {messages.map((message: any) => (
          <p key={message.id} className="text-scale-1200 text-sm whitespace-pre-line">
            {message.message}
          </p>
        ))}
      </div>
      <div className="bg-scale-400 border border-scale-600 p-2 rounded-md w-[400px] space-y-8">
        <Form validateOnBlur initialValues={initialValues} validate={() => {}} onSubmit={onSubmit}>
          {({ isSubmitting }: any) => {
            return (
              <Input
                id="message"
                name="message"
                placeholder="Type something"
                autoComplete="off"
                maxLength={100}
                actions={[
                  <div key="message-submit" className="mr-1">
                    <Button
                      key="submit"
                      htmlType="submit"
                      icon={<IconSend />}
                      loading={isSubmitting}
                      disabled={isSubmitting}
                    />
                  </div>,
                ]}
              />
            )
          }}
        </Form>
      </div>
    </div>
  )
}

export default Chatbox
