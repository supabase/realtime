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


const totalUsersDom = document.querySelector("#total-users");
const totalRedDom = document.querySelector("#total-red");
const totalBlueDom = document.querySelector("#total-blue");
const currentTeamDom = document.querySelector("#current-team");
const typingDom = document.querySelector("div[role=presence]");
function renderOnlineUsers(presence) {
  let response = "";
  let totalUsers = 0;
  let totalRed = 0;
  let totalBlue = 0;

  presence.list((userId, { metas: [first, ...rest] }) => {
    totalUsers++;
    if (first.team == 'red') totalRed++;
    else totalBlue++;
    
    response += `<br>User: <code>${userId}</code> , (typing: ${first.typing})</br>`;
    if (first.mouse && first.mouse.x)
      draw(first.color, first.mouse.x, first.mouse.y);
  });

  typingDom.innerHTML = response;
  totalUsersDom.innerHTML = `<code>${totalUsers}</code>`;
  totalRedDom.innerHTML = `${totalRed}`;
  totalBlueDom.innerHTML = `${totalBlue}`;
}
presence.onSync(() => renderOnlineUsers(presence));

socket.connect();
channel.join();

const red = '#EF4444';
const blue = "#3B82F6";
const team = Math.random() < 0.5 ? 'red' : 'blue'

let state = {
  typing: false,
  color: team == 'red' ? red : blue,
  team: team,
  mouse: {
    x: 0,
    y: 0,
  },
};
channel.push("broadcast", state);
currentTeamDom.innerHTML = `${team}`;

// TYPING EXAMPLE
const TYPING_TIMEOUT = 600;
var typingTimer;

const userStartsTyping = function () {
  if (state.typing) return;
  state = { ...state, typing: true };
  channel.push("broadcast", state);
};

const userStopsTyping = function () {
  clearTimeout(typingTimer);
  state = { ...state, typing: false };
  channel.push("broadcast", state);
};

let textbox = document.querySelector("#typingInput");
textbox.addEventListener("keydown", () => {
  userStartsTyping();
  clearTimeout(typingTimer);
});
textbox.addEventListener("keyup", () => {
  clearTimeout(typingTimer);
  typingTimer = setTimeout(userStopsTyping, TYPING_TIMEOUT);
});

/**
 * Drawing example
 */
var canvas = document.getElementById("imgCanvas");
var context = canvas.getContext("2d");

window.addEventListener(
  "mousemove",
  (e) => {
    var pos = getMousePosOffset(canvas, e);
    let x = pos.x;
    let y = pos.y;
    if (x > 0 && x < canvas.width && y > 0 && y < canvas.height) {
      state = { ...state, mouse: { x, y } };
      channel.push("broadcast", state);
    }
  },
  false
);

function draw(color, x, y) {
  context.fillStyle = color;
  context.fillRect(x, y, 4, 4);
}
function getMousePosOffset(canvas, evt) {
  var rect = canvas.getBoundingClientRect();
  return {
    x: ((evt.clientX - rect.left) / (rect.right - rect.left)) * canvas.width,
    y: ((evt.clientY - rect.top) / (rect.bottom - rect.top)) * canvas.height,
  };
}
