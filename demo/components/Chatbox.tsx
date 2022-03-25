import { FC } from "react";
import { Button, Form, IconSend, Input } from "@supabase/ui";
import { uuidv4 } from "../lib/helpers";
import { Message } from "../types/main.type";

interface Props {
  messages: Message[];

  // Probably can remove this once properly hooked up
  onAddMessage: (message: Message) => void;
}

const Chatbox: FC<Props> = ({ messages, onAddMessage }) => {
  const initialValues = { message: "" };

  const onSubmit = async (values: any, { setSubmitting, resetForm }: any) => {
    if (values.message.length === 0) return;

    const date = new Date();
    const message = {
      id: uuidv4(),
      message: values.message,
      created_at: date.toISOString(),
    };
    console.log("Send message:", values.message);
    onAddMessage(message);
    resetForm();
  };

  return (
    <div className="flex flex-col">
      <div
        className="space-y-1 rounded py-2 px-3"
        style={{ backgroundColor: "rgba(0, 207, 144, 0.05)" }}
      >
        {messages.length === 0 && (
          <p className="text-scale-1200 text-sm opacity-75">
            Start chatting 🥳
          </p>
        )}
        {messages.map((message: any) => (
          <p key={message.id} className="text-scale-1200 text-sm">
            {message.message}
          </p>
        ))}
      </div>
      <div className="bg-scale-400 border border-scale-600 p-2 rounded-md w-[400px] space-y-8">
        <Form
          validateOnBlur
          initialValues={initialValues}
          validate={() => {}}
          onSubmit={onSubmit}
        >
          {({ isSubmitting }: any) => {
            return (
              <Input
                id="message"
                name="message"
                placeholder="Type something"
                actions={[
                  <div className="mr-1">
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
            );
          }}
        </Form>
      </div>
    </div>
  );
};

export default Chatbox;
