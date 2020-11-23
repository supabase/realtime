// We need to import the CSS so that webpack will load it.
// The MiniCssExtractPlugin is used to separate it out into
// its own CSS file.
import "../css/app.scss";

// webpack automatically bundles all modules in your
// entry points. Those entry points can be configured
// in "webpack.config.js".
//
// Import deps with the dep name or local files with a relative path, for example:
//
//     import {Socket} from "phoenix"
//     import socket from "./socket"
//
import "phoenix_html";

import { Socket, Presence } from "phoenix";

function uuidv4() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
    var r = (Math.random() * 16) | 0,
      v = c == "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

  console.log("uuidv4()", uuidv4());

let socket = new Socket("/socket", {
  params: { user_id: uuidv4() },
});

let channel = socket.channel("room:lobby", {});
let presence = new Presence(channel);

function renderOnlineUsers(presence) {
  let response = "";

  presence.list((userId, { metas: [first, ...rest] }) => {
    let count = rest.length + 1;
    console.log("first", first);
    console.log("rest", rest);
    response += `<br>${userId} (count: ${count}), (typing: ${first.typing})</br>`;
  });

  document.querySelector("div[role=presence]").innerHTML = response;
}
presence.onSync(() => renderOnlineUsers(presence));

socket.connect();
channel.join();

let state = {
  typing: false,
};
channel.push("broadcast", state);

// TYPING EXAMPLE
const TYPING_TIMEOUT = 1000;
var typingTimer;

const userStartsTyping = function () {
  if (state.typing) return;
  state = {...state, typing: true}
  channel.push("broadcast", state);
};

const userStopsTyping = function () {
  clearTimeout(typingTimer);
  state = { ...state, typing: false };
  channel.push("broadcast", state);
};

let textbox = document.querySelector("#typingInput");
textbox.addEventListener("keydown", () => {
  console.log('keydown')
  userStartsTyping();
  clearTimeout(typingTimer);
});
textbox.addEventListener("keyup", () => {
  console.log("keyup");
  clearTimeout(typingTimer);
  typingTimer = setTimeout(userStopsTyping, TYPING_TIMEOUT);
});


// channel.push('shout', {
//     mouse: {
//         x: 0,
//         y: 0,
//     }
// })
