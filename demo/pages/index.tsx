import type { NextPage } from "next";
import { useEffect } from "react";
import { useRouter } from "next/router";
import { Button } from "@supabase/ui";
import RealtimeClientV2 from "../client/RealtimeClient";

const TOKEN =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjQ1MjEzMzE4LCJleHAiOjE5NjA3ODkzMTh9.KM08AjDI_zMMarPJfojM4A5Wg4Uv-ENg9AP3-B4E6Xk";

const Home: NextPage = () => {
  const router = useRouter();

  useEffect(() => {
    const client = new RealtimeClientV2(
      "ws://dev_tenant.localhost:4000/socket",
      {
        params: {
          apikey: TOKEN,
        },
      }
    );

    client.connect();

    client.setAuth(TOKEN);

    const channel = client.channel("realtime:*", {
      user_token: TOKEN,
    });

    channel.on("realtime", (payload: any) => console.log("payload", payload), {
      event: "*",
    });

    channel.on("broadcast", (payload: any) => console.log("payload", payload), {
      event: "POS",
    });

    channel.subscribe();

    channel.send({ type: "broadcast", event: "POS", payload: { x: 0, y: 0 } });
    channel.send({ type: "broadcast", event: "POS", payload: { x: 0, y: 0 } });

    console.log("channel", channel);
  }, []);

  return (
    <div className="bg-scale-200 h-screen w-screen flex flex-col items-center justify-center space-y-4">
      <span className="flex h-5 w-5 relative">
        <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-900 opacity-75"></span>
        <span className="relative inline-flex rounded-full h-full w-full bg-green-900"></span>
      </span>
      <Button size="tiny" onClick={() => router.push("/room")}>
        Go to room
      </Button>
    </div>
  );
};

export default Home;
