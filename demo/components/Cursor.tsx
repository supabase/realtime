import { FC } from "react";
import randomColor from "randomcolor";
import { IconMousePointer } from "@supabase/ui";

interface Props {
  x: number;
  y: number;
  color: string;
}

const Cursor: FC<Props> = ({ x, y, color }) => {
  return (
    <IconMousePointer
      style={{ color, transform: `translateX(${x}px) translateY(${y}px)` }}
      className="absolute top-0 left-0 transform"
      size={24}
      strokeWidth={2}
    />
  );
};

export default Cursor;
