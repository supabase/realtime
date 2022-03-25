import { FC } from "react";
import { User } from "../types/main.type";

interface Props {
  users: User[];
}

const Users: FC<Props> = ({ users }) => {
  return (
    <div className="relative">
      {users.map((user, idx: number) => {
        return (
          <div
            key={user.id}
            className={[
              "absolute right-0 h-10 w-10 bg-scale-1200 rounded-full bg-center bg-[length:50%_50%]",
              "bg-no-repeat shadow-md flex items-center justify-center border-2 border-scale-1200",
            ].join(" ")}
            style={{
              background: user.color,
              transform: `translateX(${
                Math.abs(idx - (users.length - 1)) * -20
              }px)`,
            }}
          ></div>
        );
      })}
    </div>
  );
};

export default Users;
