import type { NextPage } from "next";
import randomColor from "randomcolor";
import { useEffect, useState } from "react";
import { Button } from "@supabase/ui";

import { User, Message } from "../types/main.type";
import { uuidv4, getRandomNumberWithinRange } from "../lib/helpers";
import RealtimeClientV2 from "../client/RealtimeClient";
import Users from "../components/Users";
import Cursor from "../components/Cursor";
import Chatbox from "../components/Chatbox";
import WaitlistPopover from "../components/WaitlistPopover";

const Room: NextPage = () => {
  useEffect(() => {}, []);

  /**
   * [Joshen] I'm guessing the data structure could be something like this?
   * We'd assign a randomColor + avatar each time a user joins the session
   * This state will be within the realtime session though, not within the client
   * side, but just scaffolding for now.
   */

  const [users, setUsers] = useState<User[]>([
    { id: uuidv4(), x: 400, y: 500, color: randomColor() },
    { id: uuidv4(), x: 800, y: 300, color: randomColor() },
  ]);

  // I'm guessing messages don't have to be stored in the DB? They can just within
  // the realtime session as well. Less data to handle too?
  // Probably just keep a max of 10 messages on screen at a time or something
  const [messages, setMessages] = useState<Message[]>([]);

  const addUser = () => {
    // Max size for the room
    if (users.length === 5) return;

    const x = getRandomNumberWithinRange(100, 1000);
    const y = getRandomNumberWithinRange(100, 600);
    const randomUser = { id: uuidv4(), x, y, color: randomColor() };
    const updatedUsers = users.concat([randomUser]);
    setUsers(updatedUsers);
  };

  const removeUser = () => {
    if (users.length === 0) return;
    const updatedUsers = users.slice(0, users.length - 1);
    setUsers(updatedUsers);
  };

  const onAddMessage = (message: Message) => {
    // Max 10 messages at any point in time
    const updatedMessages =
      messages.length === 10
        ? messages.slice(1, messages.length).concat([message])
        : messages.concat([message]);
    setMessages(updatedMessages);
  };

  return (
    <div
      className="h-screen w-screen p-4 animate-gradient flex flex-col justify-between relative"
      style={{
        background:
          "linear-gradient(-45deg, transparent, transparent, rgba(0, 89, 60, 0.5), rgba(0, 207, 144, 0.5), rgba(0, 89, 60, 0.5), transparent, transparent)",
        backgroundSize: "400% 400%",
      }}
    >
      {/* Fixed elements */}
      <div>
        <div className="flex justify-between">
          <WaitlistPopover />
          <Users users={users} />
        </div>

        {/* To remove: For debugging to visualize users manually */}
        <div className="mt-4">
          <p className="text-sm text-scale-1200">For debugging only:</p>
          <div className="flex items-center space-x-2">
            <Button type="default" className="mt-2" onClick={() => addUser()}>
              Add User
            </Button>
            <Button
              type="default"
              className="mt-2"
              onClick={() => removeUser()}
            >
              Remove User
            </Button>
          </div>
        </div>
      </div>

      <div className="flex justify-end">
        <Chatbox messages={messages} onAddMessage={onAddMessage} />
      </div>

      {/* Floating elements */}
      {users.map((user: any) => (
        <Cursor key={user.id} x={user.x} y={user.y} color={user.color} />
      ))}
    </div>
  );
};

export default Room;
