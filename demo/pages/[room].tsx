import type { NextPage } from "next";
import { useEffect } from "react";

import RealtimeClientV2 from "../client/RealtimeClient";
import WaitlistPopover from "../components/WaitlistPopover";

const Room: NextPage = () => {
  useEffect(() => {}, []);

  return (
    <div
      className="h-screen w-screen p-4 animate-gradient"
      style={{
        background:
          "linear-gradient(-45deg, transparent, transparent, #00593C,#00CF90, #00593C,  transparent, transparent)",
        backgroundSize: "400% 400%",
      }}
    >
      <WaitlistPopover />
    </div>
  );
};

export default Room;
