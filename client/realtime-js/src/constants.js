module.exports = {
    VSN: "1.0.0",
    SOCKET_STATES: {connecting: 0, open: 1, closing: 2, closed: 3},
    DEFAULT_TIMEOUT: 10000,
    WS_CLOSE_NORMAL: 1000,
    CHANNEL_STATES: {
        closed: "closed",
        errored: "errored",
        joined: "joined",
        joining: "joining",
        leaving: "leaving",
    },
    CHANNEL_EVENTS: {
        close: "phx_close",
        error: "phx_error",
        join: "phx_join",
        reply: "phx_reply",
        leave: "phx_leave",
    },
    TRANSPORTS: {
        websocket: "websocket",
    },
}
