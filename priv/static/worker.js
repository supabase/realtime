addEventListener("message", (e) => {
  if (e.data === "start") {
    setInterval(() => postMessage("keepAlive"), 30000);
  }
});
